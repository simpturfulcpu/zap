module Zap::Resolver
  @git_url : Utils::GitUrl

  struct Git < Base
    def initialize(@state, @package_name, @version = "latest", @aliased_name = nil)
      super
      @git_url = Utils::GitUrl.new(@version.to_s, @state.reporter)
    end

    def resolve(parent_pkg : Package | Lockfile::Root, *, dependent : Package? = nil) : Package
      pkg = nil
      lockfile_ref = aliased_name || self.package_name
      if !lockfile_ref.empty? && (lockfile_version_or_alias = parent_pkg.pinned_dependencies[lockfile_ref]?)
        if lockfile_version_or_alias.is_a?(String)
          packages_ref = "#{self.package_name}@#{lockfile_version_or_alias}"
        else
          packages_ref = lockfile_version_or_alias.key
        end
        pkg = state.lockfile.packages[packages_ref]?
        # Validate the lockfile version
        if pkg
          pkg = nil unless pkg.dist.as?(Package::GitDist).try(&.version.== version.to_s)
        end
      end
      pkg ||= fetch_metadata
      on_resolve(pkg, parent_pkg, pkg.dist.as(Package::GitDist).commit_hash, dependent: dependent)
      pkg
    end

    def store(metadata : Package, &on_downloading) : Bool
      cache_key = metadata.dist.as(Package::GitDist).cache_key
      cloned_folder_path = Path.new(Dir.tempdir, cache_key)
      tarball_path = @state.store.package_path(@package_name, cache_key + ".tgz")
      packed = ::File.exists?(tarball_path)

      # If the tarball is there, early return
      return false if packed

      cloned = ::File.directory?(cloned_folder_path)
      yield
      # Clone the repo and run the prepare script if needed
      begin
        @state.reporter.on_packing_package
        unless cloned
          @git_url.clone(cloned_folder_path)
          prepare_package(cloned_folder_path) if metadata.has_prepare_script
        end
        # Pack the package into a tarball and remove the cloned folder
        pack_package(cloned_folder_path, tarball_path)
      ensure
        @state.reporter.on_package_packed
      end
      FileUtils.rm_rf(cloned_folder_path)
      true
    rescue e
      FileUtils.rm_rf(cloned_folder_path) if cloned_folder_path
      FileUtils.rm_rf(tarball_path) if tarball_path
      raise e
    end

    def is_lockfile_cache_valid?(cached_package : Package) : Bool
      false
    end

    private def fetch_metadata
      path = uninitialized Path
      cache_key = uninitialized String
      metadata_path = uninitialized Path
      metadata_cached = false
      fresh_clone = false
      commit_hash = nil
      @git_url.clone do |hash|
        commit_hash = hash
        cache_key = Digest::SHA1.hexdigest("zap--git-#{@git_url.base_url}-#{hash}")
        metadata_path = @state.store.package_path(@package_name, cache_key + ".package.json")
        path = Path.new(Dir.tempdir, cache_key)
        if ::File.directory?(path) || (metadata_cached = ::File.exists?(metadata_path))
          # Skip cloning
          nil
        else
          fresh_clone = true
          path
        end
      end
      commit_hash ||= @git_url.class.commit_hash(path) # legacy, should be removed I guess?
      Package.init(metadata_cached ? metadata_path : path, append_filename: !metadata_cached).tap do |pkg|
        unless metadata_cached
          ::Dir.mkdir_p(::File.dirname(metadata_path))
          ::File.write(metadata_path, pkg.to_json)
        end
        pkg.dist = Package::GitDist.new(commit_hash, version.to_s, cache_key)
        # See: https://docs.npmjs.com/cli/v9/using-npm/scripts#life-cycle-scripts
        # NOTE: If a package being installed through git contains a prepare script,
        # its dependencies and devDependencies will be installed, and the prepare script will be run,
        # before the package is packaged and installed.
        if fresh_clone
          begin
            @state.reporter.on_packing_package
            package_config = state.config.copy_with(prefix: path.to_s, global: false, silent: true)
            if pkg.scripts.try &.has_install_from_git_related_scripts?
              prepare_package(path)
            end
            pkg.scripts.try &.run_script(:prepack, path, package_config)
            pack_package(path, @state.store.package_path(@package_name, cache_key + ".tgz"))
            FileUtils.rm_rf(path)
            @state.reporter.on_package_packed
          rescue e
            FileUtils.rm_rf(path)
            raise e
          end
        end
      end
    end

    private def prepare_package(path : Path, config : Config = state.config.copy_with(prefix: path.to_s, global: false, silent: true))
      Zap::Commands::Install.run(
        config,
        Config::Install.new
      )
    end

    private def pack_package(package_path : Path, target_path : Path)
      Dir.mkdir_p(target_path.dirname) # Create folder if needed
      Compress::Gzip::Writer.open(::File.new(target_path.to_s, "w"), sync_close: true) do |gzip|
        tar_writer = Crystar::Writer.new(gzip, sync_close: true)
        Utils::File.crawl_package_files(package_path) do |path|
          full_path = Path.new(path)
          relative_path = full_path.relative_to(package_path)
          if ::File.directory?(full_path)
            Utils::TarGzip.pack_folder(full_path, tar_writer)
            false
          else
            Utils::TarGzip.pack_file(relative_path, full_path, tar_writer)
          end
        end
      ensure
        tar_writer.try &.close
      end
    end
  end
end
