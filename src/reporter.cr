require "term-cursor"

class Zap::Reporter
  @lock = Mutex.new
  @io_lock = Mutex.new
  @out : IO
  @lines = Atomic(Int32).new(0)
  @logs : Array(String) = [] of String

  def initialize(@out = STDOUT)
    @resolving_packages = Atomic(Int32).new(0)
    @resolved_packages = Atomic(Int32).new(0)
    @downloading_packages = Atomic(Int32).new(0)
    @downloaded_packages = Atomic(Int32).new(0)
    @installing_packages = Atomic(Int32).new(0)
    @installed_packages = Atomic(Int32).new(0)
    @added_packages = SafeArray(String).new
    @removed_packages = SafeArray(String).new
    @update_channel = Channel(Int32?).new
    @cursor = Term::Cursor
  end

  def on_resolving_package
    @resolving_packages.add(1)
    update()
  end

  def on_package_resolved
    @resolved_packages.add(1)
    update()
  end

  def on_downloading_package
    @downloading_packages.add(1)
    update()
  end

  def on_package_downloaded
    @downloaded_packages.add(1)
    update()
  end

  def on_package_installed
    @installed_packages.add(1)
    update()
  end

  def on_installing_package
    @installing_packages.add(1)
    update()
  end

  def on_package_added(pkg_key : String)
    @added_packages << pkg_key
  end

  def on_package_removed(pkg_key : String)
    @removed_packages << pkg_key
  end

  def stop
    @lock.synchronize do
      @update_channel.close
      @out.puts ""
    end
  end

  def update
    @lock.synchronize do
      @update_channel.send 0 unless @update_channel.closed?
    end
  end

  class ReporterPipe < IO
    def read(slice : Bytes)
      raise "Cannot read from a pipe"
    end

    def write(slice : Bytes) : Nil
      Zap.reporter.prepend(slice)
    end
  end

  def prepend(bytes : Bytes)
    @io_lock.synchronize do
      @out << @cursor.clear_lines(@lines.get, :up)
      @out << String.new(bytes)
      @out.flush
    end
  end

  def prepend(str : String)
    @io_lock.synchronize do
      @out << @cursor.clear_lines(@lines.get, :up)
      @out << str
      @out.flush
    end
  end

  def log(str : String)
    @io_lock.synchronize do
      @logs << str
    end
  end

  def header(emoji, str, color = nil)
    %( ○ #{emoji} #{str.ljust(25).colorize(color).mode(:bright)})
  end

  def report_resolver_updates
    @update_channel = Channel(Int32?).new
    spawn(same_thread: true) do
      @lines.set(1)
      loop do
        msg = @update_channel.receive?
        break if msg.nil?
        @io_lock.synchronize do
          @out << @cursor.clear_lines(@lines.get, :up)
          @out << header("🔍", "Resolving…", :yellow) + %([#{@resolved_packages.get}/#{@resolving_packages.get}])
          if (downloading = @downloading_packages.get) > 0
            @out << "\n"
            @out << header("🛰️", "Downloading…", :cyan) + %([#{@downloaded_packages.get}/#{downloading}])
            @lines.set(2)
          else
            @lines.set(1)
          end
          @out.flush
        end
      end
    end
  end

  def report_installer_updates
    @update_channel = Channel(Int32?).new
    spawn(same_thread: true) do
      loop do
        msg = @update_channel.receive?
        break if msg.nil?
        @io_lock.synchronize do
          @out << @cursor.clear_line
          @out << header("💾", "Installing…", :magenta) + %([#{@installed_packages.get}/#{@installing_packages.get}])
          @out.flush
        end
      end
    end
  end

  def report_done(realtime, memory)
    @io_lock.synchronize do
      if @logs.size > 0
        @out << header("📝", "Logs", :blue)
        @out << "\n"
        if @logs.size > 0
          separator = "\n   • ".colorize(:default)
          @out << separator
          @out << @logs.join(separator)
          @out << "\n\n"
        end
      end

        # print added / removed packages
      all_packages = @added_packages.map { |pkg_key| {pkg_key, true }} + @removed_packages.map { |pkg_key| {pkg_key, false }}
      if all_packages.size > 0
        @out << header("📦", "Dependencies", :light_yellow) + %(Added: #{@added_packages.size}, Removed: #{@removed_packages.size}).colorize.mode(:dim).to_s
        @out << "\n\n"
        all_packages.map{ |pkg_key, added|
          parts = pkg_key.split("@")
          {
            parts[...-1].join("@").colorize.mode(:bold).to_s + (" " + parts.last).colorize.mode(:dim).to_s,
            added
          }
        }.sort_by(&.[0]).each do |pkg_key, added|
          if added
            @out << "   #{"＋".colorize(:green).mode(:bold)} #{pkg_key}\n"
          else
            @out << "   #{"－".colorize(:red).mode(:bold)} #{pkg_key}\n"
          end
        end
        @out << "\n"
      end

      @out << header("👌", "Done!", :green)
      if realtime
        @out << ("took " + realtime.total_seconds.humanize + "s • ").colorize.mode(:dim)
      end
      if memory
        @out << ("memory usage " + memory.humanize + "B").colorize.mode(:dim)
      end
      @out << "\n"
    end
  end

  protected def self.format_pkg_keys(pkgs)
    pkgs.map{ |pkg_key|
      parts = pkg_key.split("@")
      parts[...-1].join("@").colorize.mode(:bold).to_s + ("@" + parts.last).colorize.mode(:dim).to_s
    }.sort!
  end
end
