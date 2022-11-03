require "../utils/fetch"
require "digest"
require "compress/gzip"
require "base64"
require "crystar"
require "./resolver"
require "../package"
require "../semver"

ACCEPT_HEADER = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*"
HEADERS       = HTTP::Headers{"Accept" => ACCEPT_HEADER}

module Resolver
  class Registry < Base
    class_getter base_url : String = "https://registry.npmjs.org"
    getter package_name : String
    getter version : String | Semver::SemverSets?
    getter metadata : Package?
    @@client_pool = nil

    def self.init(store, base_url = nil)
      @@base_url = base_url if base_url
      fetch_cache = Fetch::Cache::InMemory.new(fallback: Fetch::Cache::InStore.new(store))
      @@client_pool ||= Fetch::Pool.new(@@base_url, 50, cache: fetch_cache) { |client|
        client.read_timeout = 10.seconds
        client.write_timeout = 1.seconds
        client.connect_timeout = 1.second
      }
    end

    def initialize(@package_name, @store : Store, @version = "latest")
    end

    def find_valid_version(manifest_str : String, version : Semver::SemverSets) : Package
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

    def fetch_metadata : Package?
      raise "Resolver::Registry has not been initialized" unless client_pool = @@client_pool
      version = self.version
      base_url = @@base_url

      @metadata = begin
        if version.nil? || version.is_a?(String) || version.exact_match?
          url = "/#{package_name}/#{version || "latest"}"
          Package.from_json(client_pool.cached_fetch(url, HEADERS))
        else
          manifest = client_pool.cached_fetch("/#{package_name}", HEADERS)
          find_valid_version(manifest, version)
        end
      end
    end

    def download : Package?
      raise "Resolver::Registry has not been initialized" unless client_pool = @@client_pool
      metadata = @metadata
      raise "No metadata available" if metadata.nil?
      return if @store.package_exists?(metadata.name, metadata.version)

      dist = metadata.dist.not_nil!
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
          Compress::Gzip::Reader.open(io) do |gzip|
            Crystar::Reader.open(gzip) do |tar|
              @store.init_package(package_name, version)
              tar.each_entry do |entry|
                file_path = Path.new(entry.name.split("/")[1..-1].join("/"))
                if (entry.flag === Crystar::DIR)
                  @store.store_package_dir(package_name, version, file_path)
                else
                  @store.store_package_file(package_name, version, file_path, entry.io)
                end
              rescue e
                puts e, package_name, version, entry.name, file_path
                # Ignore
              end
            end
            gzip.skip_to_end if io.peek.try(&.size.> 0)
          end

          computed_hash = io.final
          if unsupported_algorithm
            if computed_hash.hexstring != shasum
              @store.remove_package(package_name, version)
              raise "shasum mismatch for #{tarball_url} (#{shasum})"
            end
          else
            if Base64.strict_encode(computed_hash) != hash
              @store.remove_package(package_name, version)
              raise "integrity mismatch for #{tarball_url} (#{integrity})"
            end
          end
          @store.package(package_name, version)
        ensure
          io.try &.close
        end
      end
    end
  end
end
