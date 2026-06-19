module Meridian
  module Proxy
    class Manager
      PROXY_CONTAINER       = "kamal-proxy.container"
      PROXY_SERVICE         = "kamal-proxy.service"
      PROXY_NETWORK_SERVICE = "#{Runtime::Paths::SHARED_PROXY_NETWORK}-network.service"

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        @output : IO = STDOUT,
        audit_logger : Audit::Logger? = nil,
      )
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(@config)
        @audit_logger = audit_logger || Audit::Logger.new(@config, @ssh_executor)
      end

      def setup : Nil
        proxy = @config.resolved_proxy
        hosts = web_hosts(SetupFailed)
        network_quadlet = @quadlet_generator.network_file
        proxy_network_quadlet = @quadlet_generator.proxy_network_file
        proxy_quadlet = @quadlet_generator.proxy_container_file
        proxy_url = "http://127.0.0.1:#{proxy.http_port}/"

        hosts.each do |host|
          log(host, "Ensuring Quadlet directory exists")
          run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

          log(host, "Uploading service network Quadlet")
          upload_ssh(host, network_path, network_quadlet)

          log(host, "Uploading shared proxy network Quadlet")
          upload_ssh(host, proxy_network_path, proxy_network_quadlet)

          log(host, "Uploading proxy Quadlet")
          upload_ssh(host, quadlet_path, proxy_quadlet)

          log(host, "Ensuring proxy data directory exists")
          run_ssh!(host, ["sudo", "install", "-d", "-m", "0755", "-o", ssh_user, "-g", ssh_user, proxy.data_dir])

          log(host, "Reloading user systemd")
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

          log(host, "Ensuring shared proxy network exists")
          ensure_shared_proxy_network(host)

          log(host, "Connecting running proxy to shared proxy network")
          connect_running_proxy_to_shared_network(host)

          log(host, "Starting #{PROXY_SERVICE}")
          run_ssh!(host, ["systemctl", "--user", "start", PROXY_SERVICE])

          log(host, "Checking proxy reachability at #{proxy_url}")
          run_ssh!(host, [
            "curl", "--silent", "--show-error", "--output", "/dev/null",
            "--write-out", "%{http_code}", "--head", proxy_url,
          ])

          @audit_logger.record(host, "proxy", "setup")
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError
        raise SetupFailed.new(ex.message || "Proxy setup failed")
      end

      def remove(force : Bool = false) : Nil
        hosts = web_hosts(RemoveFailed)

        hosts.each do |host|
          remove_current_service_routes(host)
          remove_current_manifest(host)
          @audit_logger.record(host, "proxy", "remove")

          other_services = other_service_manifests(host).map(&.service).sort!
          if other_services.present? && !force
            log(host, "Leaving shared #{PROXY_SERVICE} running; other services are registered: #{other_services.join(", ")}")
            next
          end

          log(host, "Stopping #{PROXY_SERVICE}")
          run_ssh!(host, ["systemctl", "--user", "stop", PROXY_SERVICE])

          log(host, "Removing proxy Quadlet")
          run_ssh!(host, ["rm", "-f", quadlet_path])

          log(host, "Reloading user systemd")
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError
        raise RemoveFailed.new(ex.message || "Proxy removal failed")
      end

      private def quadlet_path : String
        File.join(Quadlet::DIRECTORY, PROXY_CONTAINER)
      end

      private def network_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}.network")
      end

      private def proxy_network_path : String
        File.join(Quadlet::DIRECTORY, Runtime::Paths::SHARED_PROXY_NETWORK_FILE)
      end

      private def ensure_shared_proxy_network(host : String) : Nil
        network = Runtime::Paths::SHARED_PROXY_NETWORK
        command = "systemctl --user start #{Process.quote_posix(PROXY_NETWORK_SERVICE)} >/dev/null 2>&1 || " \
                  "podman network exists #{Process.quote_posix(network)} || " \
                  "podman network create #{Process.quote_posix(network)} >/dev/null"
        run_ssh!(host, ["sh", "-lc", command])
      end

      private def connect_running_proxy_to_shared_network(host : String) : Nil
        network = Runtime::Paths::SHARED_PROXY_NETWORK
        container = "kamal-proxy"
        command = "if podman container exists #{Process.quote_posix(container)}; then " \
                  "podman network connect #{Process.quote_posix(network)} #{Process.quote_posix(container)} >/dev/null 2>&1 || true; " \
                  "fi"
        run_ssh!(host, ["sh", "-lc", command])
      end

      private def manifest_file : String
        Runtime::Paths.manifest_file(@config.service)
      end

      private def web_hosts(error_klass : T.class) : Array(String) forall T
        web_server = @config.servers["web"]? || raise Config::UnknownRole.new("Unknown role: web")
        hosts = web_server.hosts
        raise error_klass.new("No hosts configured for role: web") if hosts.empty?

        hosts
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end

      private def run_ssh(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def run_ssh!(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run!(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def remove_current_service_routes(host : String) : Nil
        route_names = [@config.service]
        route_names << "#{@config.service}-assets" if @config.assets

        route_names.each do |route_name|
          quoted_route = Process.quote_posix(route_name)
          log(host, "Removing proxy route #{route_name}")
          run_ssh(host, ["sh", "-lc", "podman exec kamal-proxy kamal-proxy remove #{quoted_route} >/dev/null 2>&1 || true"])
        end
      end

      private def remove_current_manifest(host : String) : Nil
        run_ssh!(host, ["rm", "-f", manifest_file])
      end

      private def other_service_manifests(host : String) : Array(Runtime::ServiceManifest)
        command = "if test -d #{Process.quote_posix(Runtime::Paths::SERVICES_DIRECTORY)}; then " \
                  "find #{Process.quote_posix(Runtime::Paths::SERVICES_DIRECTORY)} -mindepth 2 -maxdepth 2 -name manifest.json " \
                  "-exec cat {} \\; -exec printf '\\n' \\;; fi"
        result = run_ssh(host, ["sh", "-lc", command])
        return [] of Runtime::ServiceManifest unless result.exit_code.zero?

        result.stdout.lines.compact_map do |line|
          text = line.strip
          next if text.empty?

          manifest = Runtime::ServiceManifest.from_json(text)
          manifest.service == @config.service ? nil : manifest
        end
      rescue ex : JSON::ParseException
        raise RemoveFailed.new("Invalid Meridian service manifest on #{host}: #{ex.message}")
      end

      private def upload_ssh(host : String, remote_path : String, content : String) : Nil
        @ssh_executor.upload(
          host,
          remote_path,
          content,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def ssh_user : String
        @config.ssh.user
      end

      private def ssh_port : Int32?
        port = @config.ssh.port
        port == 22 ? nil : port
      end

      private def ssh_identity_file : String?
        @config.ssh.identity_file
      end

      private def ssh_proxy_jump : String?
        @config.ssh.proxy_jump
      end

      private def ssh_connect_timeout : Int32
        @config.ssh.connect_timeout
      end

      private def ssh_keepalive : Bool
        @config.ssh.keepalive?
      end

      private def ssh_keepalive_interval : Int32
        @config.ssh.keepalive_interval
      end
    end
  end
end
