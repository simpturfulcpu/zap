require "../resolvers/resolver"
require "../installers/**"
require "../workspaces"

module Zap::Commands::Install
  record State,
    config : Config,
    install_config : Config::Install,
    store : Store,
    main_package : Package,
    lockfile : Lockfile,
    context : InferredContext,
    pipeline = Pipeline.new,
    reporter : Reporter = Reporter::Interactive.new

  def self.run(
    config : Config,
    install_config : Config::Install,
    *,
    reporter : Reporter? = nil,
    store : Store? = Store.new(config.global_store_path)
  )
    state = uninitialized State
    null_io = File.open(File::NULL, "w")

    Zap.print_banner unless config.silent

    realtime, memory = self.measure do
      global_store_path = config.global_store_path
      Resolver::Registry.init(global_store_path)

      inferred_context = infer_context(config, install_config)
      workspaces = inferred_context.workspaces
      config = inferred_context.config
      # Merge zap config from package.json
      install_config = install_config.merge_pkg(inferred_context.main_package)

      reporter ||= config.silent ? Reporter::Interactive.new(null_io) : Reporter::Interactive.new
      lockfile = Lockfile.new(config.prefix)

      unless config.silent
        puts <<-TERM
            #{"project:".colorize.blue} #{config.prefix} • #{"store:".colorize.blue} #{global_store_path} • #{"workers:".colorize.blue} #{Crystal::Scheduler.nb_of_workers}
            #{"lockfile:".colorize.blue} #{lockfile.read_status.from_disk? ? "ok".colorize.green : lockfile.read_status.error? ? "read error".colorize.red : "not found".colorize.red} • #{"install strategy:".colorize.blue} #{install_config.install_strategy.to_s.downcase}
        TERM
      end

      unless config.silent
        if workspaces
          puts <<-TERM
              #{"install scope".colorize.blue}: #{inferred_context.install_scope.size} package(s) • #{inferred_context.scope_names(:install).join(", ")}
          TERM
        end
        if (
             (install_config.removed_packages.size > 0 || install_config.added_packages.size > 0) &&
             inferred_context.add_remove_scope.size != inferred_context.install_scope.size
           )
          puts <<-TERM
              #{"add/remove scope".colorize.blue}: #{inferred_context.add_remove_scope.size} package(s) • #{inferred_context.scope_names(:add_remove).join(", ")}
          TERM
        end
        puts "\n"
      end

      # Init state struct
      state = State.new(
        config: config,
        install_config: config.global ? install_config.copy_with(
          install_strategy: Config::InstallStrategy::Classic_Shallow
        ) : install_config,
        store: store,
        main_package: inferred_context.main_package,
        lockfile: lockfile,
        reporter: reporter,
        context: inferred_context
      )

      # Remove packages if specified from the CLI
      remove_packages(state)

      # Resolve all dependencies
      resolve_dependencies(state)

      # Prune lockfile before installing to cleanup pinned dependencies
      pruned_direct_dependencies = clean_lockfile(state)

      # Do not edit lockfile or package.json files in global mode or if the save flag is false
      unless state.config.global || !state.install_config.save
        # Write lockfile
        state.lockfile.write

        # Edit and write the package.json file if the flags have been set in the config
        write_package_json(state)
      end

      # Install dependencies to the appropriate node_modules folder
      installer = install_packages(state, pruned_direct_dependencies)

      # Run package.json hooks for the installed packages
      run_install_hooks(state, installer)

      # Run package.json hooks for the workspace packages
      run_own_install_hooks(state)
    end

    state.reporter.report_done(realtime, memory, state.install_config)
    null_io.try &.close
  rescue e
    puts %(\n\n❌ #{"Error(s):".colorize.red.bold}\n#{e.message})
    Zap::Log.debug { e.backtrace.map { |line| "\t#{line}" }.join("\n").colorize.red }
    null_io.try &.close
    exit ErrorCodes::INSTALL_COMMAND_FAILED.to_i32
  end

  # -PRIVATE--------------------------- #

  private def self.measure(&block) : {Time::Span, Int64}
    realtime = uninitialized Time::Span
    memory = Benchmark.memory do
      realtime = Benchmark.realtime do
        yield
      end
    end
    {realtime, memory}
  end

  alias WorkspaceScope = Array(WorkspaceOrPackage)
  alias WorkspaceOrPackage = Package | Workspaces::Workspace

  private record(InferredContext,
    main_package : Package,
    config : Config,
    workspaces : Workspaces?,
    install_scope : WorkspaceScope,
    add_remove_scope : WorkspaceScope
  ) do
    enum ScopeType
      Install
      AddRemove
    end

    private def get_scope(type : ScopeType)
      type.install? ? @install_scope : @add_remove_scope
    end

    def scope_names(type : ScopeType)
      get_scope(type).map { |pkg|
        pkg.is_a?(Package) ? pkg.name : pkg.package.name
      }
    end

    def scope_packages(type : ScopeType)
      get_scope(type).map { |pkg|
        pkg.is_a?(Package) ? pkg : pkg.package
      }
    end

    def scope_packages_and_paths(type : ScopeType)
      get_scope(type).map { |pkg|
        pkg.is_a?(Package) ? {pkg, config.prefix} : {pkg.package, pkg.path}
      }
    end
  end

  private def self.infer_context(config : Config, install_config : Config::Install) : InferredContext
    install_scope = [] of WorkspaceOrPackage
    add_remove_scope = [] of WorkspaceOrPackage

    if config.global
      # Do not check for workspaces if the global flag is set
      main_package = Package.read_package(config)
      install_scope << main_package
      add_remove_scope << main_package
    else
      # Find the nearest package.json file and workspace package.json file
      packages_data = Utils::File.find_package_files(config.prefix)
      nearest_package = packages_data.nearest_package
      nearest_package_dir = packages_data.nearest_package_dir

      raise "Could not find a package.json file in #{config.prefix} and parent folders." unless nearest_package && nearest_package_dir

      if (workspace_package_dir = packages_data.workspace_package_dir.try(&.to_s)) && (workspace_package = packages_data.workspace_package)
        workspaces = Workspaces.new(workspace_package, workspace_package_dir)
      end
      nearest_is_workspace_root = workspace_package && workspace_package.object_id == nearest_package.object_id
      nearest_workspace = workspaces.try &.find { |w| w.path == nearest_package_dir }
      # Check if the nearest package.json file is in the workspace
      if nearest_is_workspace_root || nearest_workspace
        main_package = workspace_package.not_nil!
        workspaces = workspaces.not_nil!
        # Use the workspace root directory as the prefix
        config = config.copy_with(prefix: workspace_package_dir.not_nil!)
        # Compute the scope of the workspace based on cli flags
        if filters = install_config.filters
          install_scope += workspaces.filter(filters)
          add_remove_scope = install_scope
        elsif install_config.recursive
          install_scope = [main_package, *workspaces.workspaces]
          add_remove_scope = install_scope
        else
          install_scope = [main_package, *workspaces.workspaces]
          add_remove_scope = [nearest_workspace || main_package]
        end
      else
        # Disable workspaces if the nearest package.json file is not in the workspace
        main_package = nearest_package
        workspaces = nil
        install_scope << main_package
        add_remove_scope << main_package
        # Use the nearest package.json base directory as the prefix
        config = config.copy_with(prefix: nearest_package_dir.to_s)
      end
    end

    raise "Could not find a package.json file in #{config.prefix} and parent folders." unless main_package

    main_package = main_package.tap(&.refine)

    InferredContext.new(main_package, config, workspaces, install_scope, add_remove_scope)
  end

  private def self.remove_packages(state : State)
    return unless state.install_config.removed_packages.size > 0

    [*state.context.scope_packages(:add_remove)].each do |package|
      state.install_config.removed_packages.each do |name|
        if package.dependencies && package.dependencies.try &.has_key?(name)
          package.dependencies.not_nil!.delete(name)
        elsif package.dev_dependencies && package.dev_dependencies.try &.has_key?(name)
          package.dev_dependencies.not_nil!.delete(name)
        elsif package.optional_dependencies && package.optional_dependencies.try &.has_key?(name)
          package.optional_dependencies.not_nil!.delete(name)
        end
      end
    end
  end

  private def self.resolve_dependencies(state : State)
    state.reporter.report_resolver_updates
    # Resolve overrides
    resolve_overrides(state)
    # Resolve and store dependencies
    state.context.scope_packages(:add_remove).each do |package|
      Resolver.resolve_added_packages(package, state: state)
    end
    state.context.scope_packages(:install).each do |package|
      Resolver.resolve_dependencies_of(package, state: state)
    end
    state.pipeline.await
    state.reporter.stop
  end

  private def self.resolve_overrides(state : State)
    state.lockfile.overrides = Package::Overrides.merge(state.main_package.overrides, state.lockfile.overrides)
    state.lockfile.overrides.try &.each do |name, override_list|
      override_list.each_with_index do |override, index|
        Resolver.resolve(
          nil, # no parent
          name,
          override.specifier,
          state: state,
          # do not resolve children for overrides
          single_resolution: true
        ) do |metadata|
          override_list[index] = override.copy_with(specifier: metadata.version)
        end
      end
    end
  end

  private def self.clean_lockfile(state : State)
    workspaces, main_package = {state.context.workspaces, state.main_package}
    state.lockfile.set_root(main_package)
    workspaces.try &.each do |workspace|
      state.lockfile.set_root(workspace.package)
    end
    pruned_dependencies = state.lockfile.prune
    if state.config.global
      state.install_config.removed_packages.each do |name|
        version = Package.get_pkg_version_from_json(Utils::File.join(state.config.node_modules, name, "package.json"))
        pruned_dependencies << {name, version, Package::DEFAULT_ROOT} if version
      end
    end
    pruned_dependencies.each do |(name, version)|
      key = version.is_a?(String) ? "#{name}@#{version}" : version.key
      state.reporter.on_package_removed(key)
    end
    pruned_dependencies
  end

  private def self.write_package_json(state : State)
    if state.install_config.added_packages.size > 0 || state.install_config.removed_packages.size > 0
      [*state.context.scope_packages_and_paths(:add_remove)].each do |package, location|
        package_json = JSON.parse(File.read(Path.new(location).join("package.json"))).as_h
        if deps = package.dependencies
          package_json["dependencies"] = JSON::Any.new(deps.transform_values { |v| JSON::Any.new(v) })
        else
          package_json.delete("dependencies")
        end
        if dev_deps = package.dev_dependencies
          package_json["devDependencies"] = JSON::Any.new(dev_deps.transform_values { |v| JSON::Any.new(v) })
        else
          package_json.delete("devDependencies")
        end
        if opt_deps = package.optional_dependencies
          package_json["optionalDependencies"] = JSON::Any.new(opt_deps.transform_values { |v| JSON::Any.new(v) })
        else
          package_json.delete("optionalDependencies")
        end
        File.write(Path.new(location).join("package.json"), package_json.to_pretty_json)
      end
    end
  end

  private def self.install_packages(state : State, pruned_direct_dependencies)
    state.reporter.report_installer_updates
    installer = case state.install_config.install_strategy
                when .isolated?
                  Installer::Isolated::Installer.new(state)
                when .classic?, .classic_shallow?
                  Installer::Classic::Installer.new(state)
                else
                  raise "Unsupported install strategy: #{state.install_config.install_strategy}"
                end
    installer.install
    installer.remove(pruned_direct_dependencies)
    state.reporter.stop
    installer
  end

  private def self.run_install_hooks(state : State, installer : Installer::Base)
    if !state.install_config.ignore_scripts && installer.installed_packages_with_hooks.size > 0
      state.pipeline.reset
      # Process hooks in parallel
      state.pipeline.set_concurrency(state.config.child_concurrency)
      state.reporter.report_builder_updates
      installer.installed_packages_with_hooks.each do |package, path|
        package.scripts.try do |scripts|
          state.pipeline.process do
            state.reporter.on_building_package
            scripts.run_script(:preinstall, path, state.config)
            scripts.run_script(:install, path, state.config)
            scripts.run_script(:postinstall, path, state.config)
          rescue e
            raise Exception.new("Error while running install scripts for #{package.name}@#{package.version} at #{path}\n\n#{e.message}", e)
          ensure
            state.reporter.on_package_built
          end
        end
      end

      state.pipeline.await
      state.reporter.stop
    end
  end

  private def self.run_own_install_hooks(state : State)
    unless state.install_config.ignore_scripts
      targets = state.context.scope_packages_and_paths(:install)
      ran_once = false

      targets.each do |package, path|
        ran_once = run_root_package_install_lifecycle_scripts(package, path, state, print_hooks: !ran_once)
      end
    end
  end

  private def self.run_root_package_install_lifecycle_scripts(package : Package, chdir : Path | String, state : State, *, print_hooks = false) : Bool?
    package.scripts.try do |scripts|
      if scripts.has_self_install_lifecycle?
        if print_hooks
          state.reporter.output << state.reporter.header("⏳", "Hooks") + "\n"
        end
        output_io = Reporter::ReporterFormattedAppendPipe.new(state.reporter)
        Package::LifecycleScripts::SELF_LIFECYCLE_SCRIPTS.each do |script|
          scripts.run_script(script, chdir.to_s, state.config, output_io: output_io) { |command|
            state.reporter.output << "\n   • #{package.name.colorize.bold} #{script.colorize.cyan} #{%(#{command}).colorize.dim}\n"
          }
        end
        state.reporter.output << "\n"
        return true
      end
    end
  end
end
