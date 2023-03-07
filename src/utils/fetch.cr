require "http/client"
require "json"
require "../utils/data_structures/safe_hash"
require "../utils/memo_lock"

module Zap::Fetch
  CACHE_DIR = ".fetch_cache"

  Log = Zap::Log.for(self)

  abstract class Cache
    abstract def get(url : String, etag : String?) : String?
    abstract def set(url : String, value : String, expiry : Time::Span?, etag : String?) : Nil

    def self.hash(name)
      Digest::SHA1.hexdigest(name)
    end

    class InMemory < Cache
      def initialize(@fallback : Cache? = nil)
        @cache = SafeHash(String, String).new
      end

      def get(url, etag : String? = nil, *, fallback = true) : String?
        key = self.class.hash(url)
        own = @cache[key]?
        return own if own
        if fallback
          fb = @fallback.try &.get(key, etag)
          @cache[key] = fb if fb
          fb
        end
      rescue
        # cache miss
      end

      def set(url, value, expiry : Time::Span? = nil, etag : String? = nil, *, fallback = true) : Nil
        key = self.class.hash(url)
        @cache[key] = value
        @fallback.try &.set(key, value, expiry, etag) if fallback
        value
      rescue
        # miss
      end
    end

    class InStore < Cache
      BODY_FILE_NAME = "body"
      META_FILE_NAME = "meta.json"
      @path : Path

      def initialize(global_store_path)
        @path = Path.new(global_store_path, CACHE_DIR)
        Dir.mkdir_p(@path)
      end

      def get(url, etag : String? = nil) : String?
        key = self.class.hash(url)
        path = @path / key / BODY_FILE_NAME
        return nil unless File.readable?(path)
        meta_path = @path / key / META_FILE_NAME
        meta = File.read(meta_path) if File.readable?(meta_path)
        meta = JSON.parse(meta) if meta
        meta_etag = meta.try &.["etag"]?.try &.as_s?
        if expiry = meta.try &.["expiry"]?.try &.as_i64?
          if expiry > Time.utc.to_unix
            Log.debug { "(#{url}) Cache hit - serving metadata from #{path}" }
            return File.read(path)
          end
        end
        if etag && meta_etag && meta_etag == etag
          Log.debug { "(#{url}) Cache hit (etag) - serving metadata from #{path}" }
          return File.read(path)
        end
      end

      def set(url, value, expiry : Time::Span? = nil, etag : String? = nil) : Nil
        key = self.class.hash(url)
        root_path = @path / key
        Log.debug { "(#{url}) Storing metadata at #{root_path}" }
        Dir.mkdir_p(root_path)
        File.write(root_path / BODY_FILE_NAME, value)
        File.write(root_path / META_FILE_NAME, {"etag": etag, expiry: expiry ? (Time.utc + expiry).to_unix : nil}.to_json)
      end
    end
  end

  class Pool
    include Zap::Utils::MemoLock(Nil)

    @size = 0
    @pool : Channel(HTTP::Client)

    def initialize(@base_url : String, @size = 20, @cache : Cache = Cache::InMemory.new, &block)
      @pool = Channel(HTTP::Client).new(@size)
      @size.times do
        client = HTTP::Client.new(URI.parse base_url)
        yield client
        @pool.send(client)
      end
    end

    def initialize(base_url, max_clients = 20)
      initialize(base_url, max_clients) { }
    end

    def client(retry_attempts = 3)
      retry_count = 0
      begin
        client = @pool.receive
        loop do
          retry_count += 1
          begin
            break yield client
          rescue e
            Zap::Log.debug { e.message.colorize.red.to_s + "\n" + e.backtrace.map { |line| "\t#{line}" }.join("\n").colorize.red.to_s }
            client.close
            sleep 0.5.seconds * retry_count
            raise e if retry_count >= retry_attempts
          end
        end
      end
    ensure
      client.try { |c| @pool.send(c) }
    end

    def cached_fetch(*args, **kwargs, &block) : String
      url = args[0]
      full_url = @base_url + url

      # Extract the body from the cache if possible
      # (will try in memory, then on disk if the expiry date is still valid)
      body = @cache.get(full_url)
      return body if body
      # Dedupe requests by having an inflight channel for each URL
      memo_lock(url) do
        # debug! "[fetch] getting client… #{url}"
        client do |http|
          yield http

          # debug! "[fetch] got client #{url}"

          http.head(*args, **kwargs) do |response|
            # debug! "[fetch] got response #{url}"
            raise "Invalid status code from #{url} (#{response.status_code})" unless response.status_code == 200
            etag = response.headers["ETag"]?
            # Attempt to extract the body from the cache again but this time with the etag
            body = @cache.get(full_url, etag)
            if body
              cache_control_directives, expiry = extract_cache_headers(response)
              @cache.set(full_url, body, expiry, etag)
              return body
            end
          end

          http.get(*args, **kwargs) do |response|
            # debug! "[fetch] got response #{url}"
            raise "Invalid status code from #{url} (#{response.status_code})" unless response.status_code == 200

            etag = response.headers["ETag"]?
            cache_control_directives, expiry = extract_cache_headers(response)
            body = response.body_io.gets_to_end

            if (response.headers["Content-Length"].to_i != body.bytesize)
              # I do not know why this happens, but it does sometimes.
              raise "Content-Length mismatch for #{url} (#{response.headers["Content-Length"]} != #{body.bytesize})"
            end

            @cache.set(full_url, body, expiry, etag)
          end
        end
      end

      # Cache should now be populated
      @cache.get(full_url).not_nil!
    end

    def cached_fetch(*args, **kwargs) : String
      cached_fetch(*args, **kwargs) { }
    end

    def close
      @size.times do
        @pool.receive.close
      end
      @pool.close
    end

    private def extract_cache_headers(response : HTTP::Client::Response)
      cache_control_directives = response.headers["Cache-Control"]?.try &.split(/\s*,\s*/)
      expiry = cache_control_directives.try &.find { |d| d.starts_with?("max-age=") }.try &.split("=")[1]?.try &.to_i?.try &.seconds
      {cache_control_directives, expiry}
    end
  end
end
