require "../utils/fetch"
require "digest"
require "compress/gzip"
require "base64"
require "./resolver"
require "../package"
require "../semver"

ACCEPT_HEADER = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*"
HEADERS       = HTTP::Headers{"Accept" => ACCEPT_HEADER}

module Zap::Resolver
  class Registry < Base
    class_getter base_url : String = "https://registry.npmjs.org"
    @@client_pool = nil

    @@resolved_packages = Set(String).new
    @@resolved_packages_lock = Mutex.new
    @@lock = Mutex.new

    def self.init(base_url = nil)
      @@base_url = base_url if base_url
      fetch_cache = Fetch::Cache::InMemory.new(fallback: Fetch::Cache::InStore.new)
      @@client_pool ||= Fetch::Pool.new(@@base_url, 20, cache: fetch_cache) { |client|
        client.read_timeout = 10.seconds
        client.write_timeout = 1.seconds
        client.connect_timeout = 1.second
      }
    end

    def initialize(@package_name, @version = "latest")
    end

    def resolve(parent_pkg : Lockfile | Package, *, dependent : Package? = nil, validate_lockfile = false) : Package?
      pkg = nil
      if lockfile_version = parent_pkg.locked_dependencies[self.package_name]?
        pkg = Zap.lockfile.pkgs["#{self.package_name}@#{lockfile_version}"]?
        if validate_lockfile && pkg
          range_set = self.version
          invalidated =
            !pkg.kind.registry? ||
              (range_set.is_a?(String) && range_set != pkg.version) ||
              (range_set.is_a?(Semver::SemverSets) && !range_set.valid?(pkg.version))
          if invalidated
            pkg = nil
          end
        end
      end
      pkg ||= self.fetch_metadata
      begin
        @@resolved_packages_lock.lock
        return if @@resolved_packages.includes?(pkg.key)
        @@resolved_packages.add(pkg.key)
      ensure
        @@resolved_packages_lock.unlock
      end
      on_resolve(pkg, parent_pkg, :registry, pkg.version, dependent)
      pkg.resolve_dependencies(dependent: dependent || pkg)
      pkg
    rescue e
      puts "Error resolving #{pkg.try &.name || self.package_name} #{pkg.try &.version || self.version} #{e} #{e.backtrace.join("\n")}".colorize(:red)
    end

    def store(metadata : Package, &on_downloading) : Bool
      raise "Resolver::Registry has not been initialized" unless client_pool = @@client_pool
      return false if Store.package_exists?(metadata.name, metadata.version)

      yield

      dist = metadata.dist.not_nil!.as(Package::RegistryDist)
      tarball_url = dist[:tarball]
      integrity = dist[:integrity].try &.split(" ")[0]
      shasum = dist[:shasum]
      version = metadata.version
      unsupported_algorithm = false
      algorithm, hash, algorithm_instance = nil, nil, nil

      if integrity
        algorithm, hash = integrity.split("-")
      else
        unsupported_algorithm = true
      end

      algorithm_instance = case algorithm
                           when "sha1"
                             Digest::SHA1.new
                           when "sha256"
                             Digest::SHA256.new
                           when "sha512"
                             Digest::SHA512.new
                           else
                             unsupported_algorithm = true
                             Digest::SHA1.new
                           end

      client_pool.client &.get(tarball_url) do |response|
        raise "Invalid status code from #{tarball_url} (#{response.status_code})" unless response.status_code == 200
        IO::Digest.new(response.body_io, algorithm_instance).try do |io|
          Store.store_tarball(package_name, version, io)

          computed_hash = io.final
          if unsupported_algorithm
            if computed_hash.hexstring != shasum
              Store.remove_package(package_name, version)
              raise "shasum mismatch for #{tarball_url} (#{shasum})"
            end
          else
            if Base64.strict_encode(computed_hash) != hash
              Store.remove_package(package_name, version)
              raise "integrity mismatch for #{tarball_url} (#{integrity})"
            end
          end
          Store.package(package_name, version)
        ensure
          io.try &.close
        end
        true
      end
    end

    # # PRIVATE ##########################

    private def find_valid_version(manifest_str : String, version : Semver::SemverSets) : Package
      matching = nil
      manifest_parser = JSON::PullParser.new(manifest_str)
      manifest_parser.read_begin_object
      loop do
        break if manifest_parser.kind.end_object?
        key = manifest_parser.read_object_key
        if key === "versions"
          manifest_parser.read_begin_object
          loop do
            break if manifest_parser.kind.end_object?
            version_str = manifest_parser.read_string
            semver = Semver::Comparator.parse(version_str)
            if matching.nil? || matching[0] < semver
              if version.valid?(version_str)
                matching = {semver, manifest_parser.read_raw}
              else
                manifest_parser.skip
              end
            else
              manifest_parser.skip
            end
          end
          break
        else
          manifest_parser.skip
        end
      end

      unless matching
        raise "No version matching range #{version} for package #{package_name} found in the module registry"
      end
      Package.from_json matching[1]
    end

    private def fetch_metadata : Package?
      raise "Resolver::Registry has not been initialized" unless client_pool = @@client_pool
      version = self.version
      base_url = @@base_url

      begin
        if version.nil? || version.is_a?(String) || version.exact_match?
          url = "/#{package_name}/#{version || "latest"}"
          Package.from_json(client_pool.cached_fetch(url, HEADERS))
        else
          manifest = client_pool.cached_fetch("/#{package_name}", HEADERS)
          find_valid_version(manifest, version)
        end
      end
    end
  end
end
