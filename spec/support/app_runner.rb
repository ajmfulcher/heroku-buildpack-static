require "uri"
require "net/http"
require "fileutils"
require "json"
require "docker"
require "concurrent/atomic/count_down_latch"
require_relative "path_helper"
require_relative "buildpack_builder"
require_relative "router_runner"
require_relative "../../scripts/config/lib/nginx_config_util"

class AppRunner
  include PathHelper

  attr_reader :proxy

  def initialize(fixture, proxy = nil, env = {}, debug = false)
    @run       = false
    @debug     = debug
    @tmpdir    = nil
    @proxy     = nil
    env.merge!("STATIC_DEBUG" => "true") if @debug

    app_options = {
      "name"       => "app",
      "Image"      => BuildpackBuilder::TAG,
      # Env format is [KEY1=VAL1 KEY2=VAL2]
      "Env"        => env.to_a.map {|i| i.join("=") },
      "HostConfig" => {
        "Binds" => ["#{fixtures_path(fixture)}:/src"]
      }
    }

    if proxy
      app_options["Links"] = ["proxy:proxy"]
      if proxy.is_a?(String)
        @tmpdir = Dir.mktmpdir
        File.open("#{@tmpdir}/config.ru", "w") do |file|
          file.puts %q{require "sinatra"}
          file.puts proxy
          file.puts "run Sinatra::Application"
        end
      end

      @proxy = ProxyRunner.new(@tmpdir)
      @proxy.start

      # need to interpolate the PROXY_IP_ADDRESS since env is a parameter to this constructor and
      # the proxy app needs to be started first to get the ip address docker provides.
      # it's a bootstrapping problem to do env var substitution
      env.select {|_, value| value.include?("${PROXY_IP_ADDRESS}") }.each do |key, value|
        env[key] = NginxConfigUtil.interpolate(value, {"PROXY_IP_ADDRESS" => @proxy.ip_address})
        app_options["Env"] = env.to_a.map {|i| i.join("=") }
      end
    end

    @app    = Docker::Container.create(app_options)
    @router = RouterRunner.new
  end

  def run(capture_io = false)
    @run       = true
    retn       = nil
    latch      = Concurrent::CountDownLatch.new(1)
    io_stream  = StringIO.new
    run_thread = Thread.new {
      latch.wait(0.5)
      yield
    }
    container_thread = Thread.new {
      @app.tap(&:start).attach do |stream, chunk|
        io_message = "#{stream}: #{chunk}"
        puts io_message if @debug
        io_stream << io_message if capture_io
        latch.count_down if chunk.include?("Starting nginx...")
      end
    }
    @router.start

    retn = run_thread.value

    if capture_io
      [retn, io_stream]
    else
      retn
    end
  ensure
    @app.stop
    @router.stop
    container_thread.join
    io_stream.close_write
    @run = false
  end

  def get(path, capture_io = false, max_retries = 30)
    if @run
      get_retry(path, max_retries)
    else
      run(capture_io) { get_retry(path, max_retries) }
    end
  end

  def destroy
    if @proxy
      @proxy.stop
      @proxy.destroy
    end
    @router.destroy
    @app.delete(force: true)
  ensure
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  private
  def get_retry(path, max_retries)
    network_retry(max_retries) do
      uri = URI(path)
      uri.host   = RouterRunner::HOST_IP   if uri.host.nil?
      uri.port   = RouterRunner::HOST_PORT if (uri.host == RouterRunner::HOST_IP && uri.port != RouterRunner::HOST_PORT) || uri.port.nil?
      uri.scheme = "http"    if uri.scheme.nil?

      Net::HTTP.get_response(URI(uri.to_s))
    end
  end

  def network_retry(max_retries, retry_count = 0)
    yield
  rescue Errno::ECONNRESET, EOFError, Errno::ECONNREFUSED
    if retry_count < max_retries
      puts "Retry Count: #{retry_count}" if @debug
      sleep(0.01 * retry_count)
      retry_count += 1
      retry
    end
  end
end
