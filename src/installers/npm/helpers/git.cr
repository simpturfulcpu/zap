module Zap::Installers::Npm::Helpers::Git
  def self.install(dependency : Package, *, cache : Deque(CacheItem), state : Commands::Install::State) : Deque(CacheItem)?
    unless cloned_folder = dependency.dist.try &.as(Package::GitDist)[:path].try { |path| Path.new(path) }
      raise "Cannot install git dependency #{dependency.name} because the dist.path field is missing."
    end

    target_path = cache.last[0] / dependency.name
    FileUtils.rm_rf(target_path) if ::File.directory?(target_path)

    state.reporter.on_installing_package

    Utils::File.crawl_package_files(cloned_folder) do |path|
      if ::File.directory?(path)
        relative_dir_path = Path.new(path).relative_to(cloned_folder)
        Dir.mkdir_p(target_path / relative_dir_path)
      else
        relative_file_path = Path.new(path).relative_to(cloned_folder)
        Dir.mkdir_p((target_path / relative_file_path).dirname)
        ::File.copy(path, target_path / relative_file_path)
      end
    end

    Installer.on_install(dependency, target_path, state: state)

    cache.last[1] << dependency
    subcache = cache.dup
    subcache << {target_path / "node_modules", Set(Package).new}
  end
end