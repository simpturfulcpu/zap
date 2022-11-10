struct Zap::Store
  def self.package_path(name : String, version : String)
    Path.new(Config.global_store_path, "#{name}@#{version}")
  end

  def self.package_exists?(name : String, version : String)
    Dir.exists? package_path(name, version)
  end

  def self.init_package(name : String, version : String)
    path = package_path(name, version)
    FileUtils.rm_rf(path) if Dir.exists?(path)
    Dir.mkdir_p(path)
  end

  def self.remove_package(name : String, version : String)
    Dir.delete(package_path(name, version))
  end

  def self.store_tarball(name : String, version : String, io : IO)
    Store.init_package(name, version)
    TarGzip.unpack(io) do |entry, file_path, io|
      if (entry.flag === Crystar::DIR)
        Store.store_package_dir(name, version, file_path)
      else
        Store.store_package_file(name, version, file_path, entry.io)
      end
    end
  end

  def self.store_package_file(package_name : String, package_version : String, relative_file_path : String | Path, file_io : IO)
    file_path = package_path(package_name, package_version) / relative_file_path
    Dir.mkdir_p(file_path.dirname)
    File.open(file_path, "w") do |file|
      IO.copy file_io, file
    end
  end

  def self.store_package_dir(package_name : String, package_version : String, relative_dir_path : String | Path)
    file_path = package_path(package_name, package_version) / relative_dir_path
    Dir.mkdir_p(file_path)
  end

  def self.package(name : String, version : String)
    Package.init(package_path(name, version))
  end
end
