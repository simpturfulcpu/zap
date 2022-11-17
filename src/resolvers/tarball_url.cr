require "crystar"

module Zap::Resolver
  struct TarballUrl < Base
    @stored = false

    def resolve(parent_pkg_refs : Package::ParentPackageRefs, *, dependent : Package? = nil, validate_lockfile = false, resolve_dependencies = true) : Package?
      tarball_url = version.to_s
      store_hash = Digest::SHA1.hexdigest(tarball_url)
      temp_path = Path.new(Dir.tempdir, "zap--tarball-#{store_hash}")
      # TODO: a dedicated pool?
      unless Dir.exists?(temp_path)
        @stored = true
        HTTP::Client.get(tarball_url) do |response|
          raise "Invalid status code from #{tarball_url} (#{response.status_code})" unless response.status_code == 200
          TarGzip.unpack(response.body_io) do |entry, file_path, io|
            if (entry.flag === Crystar::DIR)
              Dir.mkdir_p(temp_path / file_path)
            else
              Dir.mkdir_p(temp_path / file_path.dirname)
              ::File.write(temp_path / file_path, io)
            end
          end
        end
      end
      Package.init(temp_path).tap { |pkg|
        pkg.dist = {tarball: tarball_url, path: temp_path.to_s}
        on_resolve(pkg, parent_pkg_refs, :tarball, tarball_url, dependent)
        pkg.resolve_dependencies(state: state, dependent: dependent || pkg) if resolve_dependencies
      }
    end

    def store(metadata : Package, &on_downloading) : Bool
      yield if @stored
      @stored
    end
  end
end
