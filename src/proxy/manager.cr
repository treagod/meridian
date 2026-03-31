module Meridian
  module Proxy
    class Manager
      PROXY_CONTAINER = "kamal-proxy.container"
      PROXY_SERVICE   = "kamal-proxy.service"

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        @output : IO = STDOUT,
      )
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(@config)
      end

      def setup : Nil
        proxy = proxy_config(SetupFailed)
        hosts = web_hosts(SetupFailed)
        quadlet = @quadlet_generator.proxy_container_file
        proxy_url = "http://127.0.0.1:#{proxy.http_port}/"

        hosts.each do |host|
          log(host, "Ensuring Quadlet directory exists")
          @ssh_executor.run!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

          log(host, "Uploading proxy Quadlet")
          @ssh_executor.upload(host, quadlet_path, quadlet)

          log(host, "Reloading user systemd")
          @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])

          log(host, "Starting #{PROXY_SERVICE}")
          @ssh_executor.run!(host, ["systemctl", "--user", "start", PROXY_SERVICE])

          log(host, "Checking proxy reachability at #{proxy_url}")
          @ssh_executor.run!(host, ["curl", "--silent", "--show-error", "--fail", "--head", proxy_url])
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError
        raise SetupFailed.new(ex.message || "Proxy setup failed")
      end

      def remove : Nil
        hosts = web_hosts(RemoveFailed)

        hosts.each do |host|
          log(host, "Stopping #{PROXY_SERVICE}")
          @ssh_executor.run!(host, ["systemctl", "--user", "stop", PROXY_SERVICE])

          log(host, "Removing proxy Quadlet")
          @ssh_executor.run!(host, ["rm", "-f", quadlet_path])

          log(host, "Reloading user systemd")
          @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError
        raise RemoveFailed.new(ex.message || "Proxy removal failed")
      end

      private def quadlet_path : String
        File.join(Quadlet::DIRECTORY, PROXY_CONTAINER)
      end

      private def web_hosts(error_klass : T.class) : Array(String) forall T
        web_server = @config.servers["web"]? || raise Config::UnknownRole.new("Unknown role: web")
        hosts = web_server.hosts
        raise error_klass.new("No hosts configured for role: web") if hosts.empty?

        hosts
      end

      private def proxy_config(error_klass : T.class) : Config::ProxyConfig forall T
        @config.proxy || raise error_klass.new("Missing proxy configuration")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
