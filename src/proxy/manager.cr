require "json"

module Meridian
  module Proxy
    class Manager
      PROXY_CONTAINER       = "meridian-caddy.container"
      PROXY_SERVICE         = "meridian-caddy.service"
      PROXY_NAME            = "meridian-caddy"
      PROXY_NETWORK_SERVICE = "#{Runtime::Paths::SHARED_PROXY_NETWORK}-network.service"
      CONFIG_DIR            = File.join(".config", "containers", PROXY_NAME)
      ROUTES_DIR            = File.join(CONFIG_DIR, "routes")
      CADDYFILE             = File.join(CONFIG_DIR, "Caddyfile")
      ADMIN_SOCKET          = File.join(CONFIG_DIR, "admin.sock")
      RELOAD_LOCK           = File.join(CONFIG_DIR, "reload.lock")
      VERSION_CHECK         = "version=$(podman exec #{PROXY_NAME} caddy version) || exit; " \
                              "printf '%s\\n' \"$version\" | awk -F. 'BEGIN { ok=0 } { gsub(/^v/, \"\", $1); ok=($1 > 2 || ($1 == 2 && ($2 > 11 || ($2 == 11 && $3 >= 2)))) } END { exit !ok }'"

      RESOLVE_TIMEOUT   = 120
      RESOLVE_SUCCESSES =   3

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        @output : IO = STDOUT,
        audit_logger : Audit::Logger? = nil,
        @drain_sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration },
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
        web_proxy = @config.servers["web"].proxy || raise SetupFailed.new("Missing proxy configuration for role: web")

        service_network_hosts.each { |host| setup_service_network(host, network_quadlet) }

        hosts.each do |host|
          log(host, "Ensuring Caddy directories exist")
          run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY, ROUTES_DIR, Runtime::Paths::ASSETS_DIRECTORY])
          data_dir_command = "path=$1; case \"$path\" in %h*) path=$HOME${path#%h};; esac; mkdir -p -- \"$path\""
          run_ssh!(host, ["sh", "-lc", data_dir_command, "meridian", proxy.data_dir])
          run_ssh!(host, ["sh", "-lc", "command -v flock >/dev/null"])

          log(host, "Uploading shared proxy network Quadlet")
          upload_ssh(host, proxy_network_path, proxy_network_quadlet)
          log(host, "Uploading Caddy configuration")
          upload_ssh(host, CADDYFILE, @quadlet_generator.proxy_caddyfile)
          ensure_initial_route(host, web_proxy)
          log(host, "Uploading Caddy Quadlet")
          upload_ssh(host, quadlet_path, proxy_quadlet)

          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
          ensure_shared_proxy_network(host)
          log(host, "Restarting #{PROXY_SERVICE}")
          run_ssh!(host, ["systemctl", "--user", "restart", PROXY_SERVICE])
          verify_caddy!(host)

          log(host, "Checking proxy reachability at #{proxy_url}")
          run_ssh!(host, [
            "curl", "--silent", "--show-error", "--retry", "10", "--retry-delay", "1", "--retry-all-errors", "--output", "/dev/null",
            "--write-out", "%{http_code}", "--head", proxy_url,
          ])
          @audit_logger.record(host, "proxy", "setup")
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError
        raise SetupFailed.new(ex.message || "Caddy setup failed")
      end

      def switch(host : String, proxy : Config::ServerProxyConfig, target : String) : Nil
        await_upstream_resolvable!(host, target)
        activate_route(host, @config.service, @quadlet_generator.proxy_route(proxy, target), expected_target: target)
      end

      def maintenance(host : String, proxy : Config::ServerProxyConfig, old_target : String) : Nil
        activate_route(host, @config.service, @quadlet_generator.proxy_maintenance_route(proxy), removed_target: old_target)
      end

      # Assets are served by this proxy straight off its read-only /srv/assets
      # mount, so there is no upstream to confirm after a reload: an SSH drop
      # mid-reload surfaces as SwitchUncertain. Route activation is idempotent,
      # so rerunning the deploy resolves it.
      def register_assets(host : String) : Nil
        raise RouteFailed.new("Missing assets configuration") unless @config.assets
        activate_route(host, "#{@config.service}-assets", @quadlet_generator.proxy_asset_route)
      end

      def register_redirects(host : String, proxy : Config::ServerProxyConfig) : Nil
        name = "#{@config.service}-redirects"
        if proxy.redirect_hosts.empty?
          deactivate_route(host, name)
        else
          activate_route(host, name, @quadlet_generator.proxy_redirects_route(proxy))
        end
      end

      def drain(host : String, target : String) : Nil
        timeout = @config.resolved_proxy.drain_timeout
        timeout.times do |elapsed|
          return if upstream_drained?(host, target)

          @drain_sleeper.call(1.second) if elapsed < timeout - 1
        end

        log(host, "Warning: #{target} still has in-flight requests after #{timeout}s; stopping it anyway")
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
          log(host, "Removing Caddy Quadlet")
          run_ssh!(host, ["rm", "-f", quadlet_path])
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | ArgumentError | RouteFailed
        raise RemoveFailed.new(ex.message || "Caddy removal failed")
      end

      # The probe sidecar can resolve a new container before Caddy can.
      private def await_upstream_resolvable!(host : String, target : String) : Nil
        name = target.rpartition(':').first
        log(host, "Waiting for Caddy to resolve #{name}")
        wait = "n=0; until [ $n -ge #{RESOLVE_SUCCESSES} ]; do " \
               "if getent hosts #{Process.quote_posix(name)} >/dev/null 2>&1; then n=$((n+1)); else n=0; fi; " \
               "[ $n -ge #{RESOLVE_SUCCESSES} ] || sleep 1; done"
        result = run_ssh(host, ["timeout", "-k", "5", RESOLVE_TIMEOUT.to_s, "podman", "exec", PROXY_NAME, "sh", "-c", wait])
        unless result.exit_code.zero?
          raise RouteFailed.new("Caddy could not resolve #{name} within #{RESOLVE_TIMEOUT}s; traffic was not switched")
        end
      rescue ex : SSH::ConnectionError
        raise RouteFailed.new("SSH disconnected while waiting for Caddy to resolve #{name}; traffic was not switched: #{ex.message}")
      end

      private def activate_route(
        host : String,
        name : String,
        content : String,
        expected_target : String? = nil,
        removed_target : String? = nil,
      ) : Nil
        active = route_path(name)
        pending = "#{active}.pending"
        backup = "#{active}.backup"
        upload_ssh(host, pending, content)

        command = "set -eu; exec 9>#{Process.quote_posix(RELOAD_LOCK)}; flock 9; " \
                  "if test -f #{Process.quote_posix(active)}; then cp #{Process.quote_posix(active)} #{Process.quote_posix(backup)}; else rm -f #{Process.quote_posix(backup)}; fi; " \
                  "mv #{Process.quote_posix(pending)} #{Process.quote_posix(active)}; " \
                  "if podman exec #{PROXY_NAME} caddy reload --config /config/Caddyfile --adapter caddyfile --address unix//config/admin.sock; then " \
                  "rm -f #{Process.quote_posix(backup)}; else " \
                  "if test -f #{Process.quote_posix(backup)}; then mv #{Process.quote_posix(backup)} #{Process.quote_posix(active)}; else rm -f #{Process.quote_posix(active)}; fi; exit 1; fi"

        result = run_ssh(host, ["sh", "-lc", command])
        return if result.exit_code.zero?

        raise RouteFailed.new(SSH::Executor.command_failure_message(host, "reload Caddy route #{name}", result))
      rescue SSH::ConnectionError
        upstreams = query_upstreams(host)
        if upstreams
          return if expected_target && upstreams.includes?(expected_target)
          raise RouteFailed.new("Caddy route #{name} was not committed on #{host}") if expected_target
          return if removed_target && !upstreams.includes?(removed_target)
        end

        raise SwitchUncertain.new(
          "SSH disconnected while reloading Caddy route #{name} on #{host}; both releases were left running. " \
          "Inspect `curl --unix-socket ~/#{ADMIN_SOCKET} http://localhost/reverse_proxy/upstreams` and rerun the deploy after confirming the active target."
        )
      end

      private def upstream_drained?(host : String, target : String) : Bool
        result = run_ssh(host, admin_curl_command("/reverse_proxy/upstreams"))
        return false unless result.exit_code.zero?

        upstreams = JSON.parse(result.stdout).as_a
        upstream = upstreams.find { |entry| entry["address"].as_s == target }
        return true unless upstream

        upstream["num_requests"].as_i64.zero?
      rescue JSON::ParseException | TypeCastError | KeyError | SSH::ConnectionError
        false
      end

      private def query_upstreams(host : String) : Array(String)?
        result = run_ssh(host, admin_curl_command("/reverse_proxy/upstreams"))
        return unless result.exit_code.zero?

        JSON.parse(result.stdout).as_a.map(&.["address"].as_s)
      rescue JSON::ParseException | TypeCastError | KeyError | SSH::ConnectionError
        nil
      end

      private def deactivate_route(host : String, name : String) : Nil
        active = route_path(name)
        backup = "#{active}.removed"
        command = "set -eu; exec 9>#{Process.quote_posix(RELOAD_LOCK)}; flock 9; " \
                  "test -f #{Process.quote_posix(active)} || exit 0; " \
                  "cp #{Process.quote_posix(active)} #{Process.quote_posix(backup)}; rm -f #{Process.quote_posix(active)}; " \
                  "if podman exec #{PROXY_NAME} caddy reload --config /config/Caddyfile --adapter caddyfile --address unix//config/admin.sock; then " \
                  "rm -f #{Process.quote_posix(backup)}; else " \
                  "mv #{Process.quote_posix(backup)} #{Process.quote_posix(active)}; exit 1; fi"

        result = run_ssh(host, ["sh", "-lc", command])
        return if result.exit_code.zero?

        raise RouteFailed.new(SSH::Executor.command_failure_message(host, "remove Caddy route #{name}", result))
      end

      private def remove_current_service_routes(host : String) : Nil
        names = [@config.service, "#{@config.service}-redirects"]
        names << "#{@config.service}-assets" if @config.assets
        active_paths = names.map { |name| route_path(name) }
        backups = active_paths.map { |path| "#{path}.removed" }
        save = active_paths.zip(backups).map do |active, backup|
          "rm -f #{Process.quote_posix(backup)}; if test -f #{Process.quote_posix(active)}; then cp #{Process.quote_posix(active)} #{Process.quote_posix(backup)}; fi"
        end.join("; ")
        remove = active_paths.map { |path| "rm -f #{Process.quote_posix(path)}" }.join("; ")
        restore = active_paths.zip(backups).map do |active, backup|
          "if test -f #{Process.quote_posix(backup)}; then mv #{Process.quote_posix(backup)} #{Process.quote_posix(active)}; fi"
        end.join("; ")
        cleanup = backups.map { |path| "rm -f #{Process.quote_posix(path)}" }.join("; ")
        command = "set -eu; exec 9>#{Process.quote_posix(RELOAD_LOCK)}; flock 9; #{save}; #{remove}; " \
                  "if podman exec #{PROXY_NAME} caddy reload --config /config/Caddyfile --adapter caddyfile --address unix//config/admin.sock; then #{cleanup}; else #{restore}; exit 1; fi"
        result = run_ssh(host, ["sh", "-lc", command])
        return if result.exit_code.zero?

        raise RouteFailed.new(SSH::Executor.command_failure_message(host, "remove Caddy routes", result))
      end

      private def verify_caddy!(host : String) : Nil
        run_ssh!(host, ["sh", "-lc", VERSION_CHECK])
        run_ssh!(host, admin_curl_command("/config/"))
      end

      private def ensure_initial_route(host : String, proxy : Config::ServerProxyConfig) : Nil
        active = route_path(@config.service)
        pending = "#{active}.pending"
        upload_ssh(host, pending, @quadlet_generator.proxy_maintenance_route(proxy))
        command = "set -eu; exec 9>#{Process.quote_posix(RELOAD_LOCK)}; flock 9; " \
                  "if test -f #{Process.quote_posix(active)}; then rm -f #{Process.quote_posix(pending)}; else mv #{Process.quote_posix(pending)} #{Process.quote_posix(active)}; fi"
        run_ssh!(host, ["sh", "-lc", command])
      end

      private def admin_curl_command(path : String) : Array(String)
        ["curl", "--silent", "--show-error", "--fail", "--unix-socket", ADMIN_SOCKET, "http://localhost#{path}"]
      end

      private def route_path(name : String) : String
        File.join(ROUTES_DIR, "#{name}.caddy")
      end

      private def quadlet_path : String
        File.join(Quadlet::DIRECTORY, PROXY_CONTAINER)
      end

      private def network_path : String
        File.join(Quadlet::DIRECTORY, Runtime::ServiceNetwork.file(@config.service))
      end

      private def proxy_network_path : String
        File.join(Quadlet::DIRECTORY, Runtime::Paths::SHARED_PROXY_NETWORK_FILE)
      end

      private def service_network_hosts : Array(String)
        hosts = @config.servers.values.flat_map(&.hosts)
        (@config.accessories || Config::EMPTY_ACCESSORIES).each_value do |accessory|
          host = accessory.host.to_s.strip
          hosts << host if accessory.network_name == @config.service && !host.empty?
        end

        hosts.uniq!
        hosts.sort!
        hosts
      end

      private def setup_service_network(host : String, network_quadlet : String) : Nil
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
        upload_ssh(host, network_path, network_quadlet)
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        run_ssh!(host, Runtime::ServiceNetwork.start_command(@config.service))
      end

      private def ensure_shared_proxy_network(host : String) : Nil
        network = Runtime::Paths::SHARED_PROXY_NETWORK
        command = "systemctl --user start #{Process.quote_posix(PROXY_NETWORK_SERVICE)} >/dev/null 2>&1 || " \
                  "podman network exists #{Process.quote_posix(network)} || " \
                  "podman network create #{Process.quote_posix(network)} >/dev/null"
        run_ssh!(host, ["sh", "-lc", command])
      end

      private def remove_current_manifest(host : String) : Nil
        run_ssh!(host, ["rm", "-f", Runtime::Paths.manifest_file(@config.service)])
      end

      private def other_service_manifests(host : String) : Array(Runtime::ServiceManifest)
        command = Runtime::ServiceManifest.list_command
        result = run_ssh(host, command)
        unless result.exit_code.zero?
          raise RemoveFailed.new(SSH::Executor.command_failure_message(host, command.join(" "), result))
        end

        Runtime::ServiceManifest.parse_all(result.stdout).reject { |manifest| manifest.service == @config.service }
      rescue ex : JSON::ParseException
        raise RemoveFailed.new("Invalid Meridian service manifest on #{host}: #{ex.message}")
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
        @ssh_executor.run(host, command, user: ssh_user, port: ssh_port, identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump, connect_timeout: ssh_connect_timeout, keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval)
      end

      private def run_ssh!(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run!(host, command, user: ssh_user, port: ssh_port, identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump, connect_timeout: ssh_connect_timeout, keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval)
      end

      private def upload_ssh(host : String, remote_path : String, content : String) : Nil
        @ssh_executor.upload(host, remote_path, content, user: ssh_user, port: ssh_port,
          identity_file: ssh_identity_file, proxy_jump: ssh_proxy_jump, connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive, keepalive_interval: ssh_keepalive_interval)
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
