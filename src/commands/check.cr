module Meridian
  module Commands
    class Check < Base
      # The oldest Podman the e2e covers; generated Quadlets need at least 4.5
      # for Secret= and HealthCmd=.
      MIN_PODMAN_MAJOR  = 4
      MIN_PODMAN_MINOR  = 9
      EMPTY_ACCESSORIES = {} of String => Config::AccessoryConfig

      private record HostContext,
        host : String,
        roles : Array(String)

      private record PodmanVersion,
        major : Int32,
        minor : Int32,
        label : String

      private record ProbeResult,
        host : String,
        probe : String,
        position : Int32,
        passed : Bool,
        detail : String

      alias LocalImageProbe = Proc(String, Bool)
      alias LocalFileProbe = Proc(String, Bool)
      alias LocalCommandProbe = Proc(String, Bool)

      DEFAULT_LOCAL_IMAGE_PROBE = ->(image : String) do
        Process.run("podman", ["image", "exists", image]).success?
rescue
  false
      end

      # Deploy reads the source; readable directories and special files fail.
      DEFAULT_LOCAL_FILE_PROBE = ->(path : String) { File.file?(path) && File::Info.readable?(path) }

      # Same primitive the transfer classes use, so the probe cannot disagree
      # with the `ensure_local_dependency!` call it is predicting.
      DEFAULT_LOCAL_COMMAND_PROBE = ->(command : String) { !Process.find_executable(command).nil? }

      @local_image_probe : LocalImageProbe
      @local_file_probe : LocalFileProbe
      @local_command_probe : LocalCommandProbe

      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        output : IO = STDOUT,
        error : IO = STDERR,
        audit_logger : ::Meridian::Audit::Logger? = nil,
        local_image_probe : LocalImageProbe? = nil,
        local_file_probe : LocalFileProbe? = nil,
        local_command_probe : LocalCommandProbe? = nil,
      )
        super(config, ssh_executor, output, error, audit_logger)
        @local_image_probe = local_image_probe || DEFAULT_LOCAL_IMAGE_PROBE
        @local_file_probe = local_file_probe || DEFAULT_LOCAL_FILE_PROBE
        @local_command_probe = local_command_probe || DEFAULT_LOCAL_COMMAND_PROBE
      end

      def run(targets : Array(CLI::TargetSelector::Target)? = nil) : Bool
        validate_batch_settings!

        rows = [] of ProbeResult
        hosts = host_contexts(targets)
        raise ArgumentError.new("No hosts configured") if hosts.empty?

        remaining_hosts = hosts.dup
        until remaining_hosts.empty?
          batch = remaining_hosts.shift(@config.boot.limit)
          channel = Channel(Array(ProbeResult)).new(batch.size)

          batch.each do |host_context|
            spawn do
              results =
                begin
                  check_host(host_context)
                rescue ex : Exception
                  [fail(host_context.host, "check", 99, "unexpected error: #{ex.class.name}: #{ex.message}")]
                end
              channel.send(results)
            end
          end

          batch.size.times do
            rows.concat(channel.receive)
          end
        end

        rows.concat(check_local_images(targets))
        rows.concat(check_local_transfer_tools)
        rows.concat(check_local_files(targets))
        rows.concat(check_accessory_readiness_resolution)

        print_rows(rows)
        passed = rows.all?(&.passed)
        @output.puts(passed ? "Check passed" : "Check failed")
        passed
      end

      private def check_local_images(targets : Array(CLI::TargetSelector::Target)?) : Array(ProbeResult)
        mode = @config.transfer.try(&.mode)
        return [] of ProbeResult if mode.nil? || mode.registry?

        selected_local_images(targets).map_with_index do |image, index|
          if @local_image_probe.call(image)
            pass("local", "image:#{image}", index, "present")
          else
            fail("local", "image:#{image}", index, "not found locally; build or pull it first")
          end
        end
      end

      # Transfers also need local tools; check before starting a deploy.
      private def check_local_transfer_tools : Array(ProbeResult)
        local_transfer_tools.map_with_index do |tool, index|
          position = 60 + index
          if @local_command_probe.call(tool)
            pass("local", "tool:#{tool}", position, "found")
          else
            fail("local", "tool:#{tool}", position, "not found locally; install it to use transfer mode #{@config.transfer.try(&.mode)}")
          end
        end
      end

      private def selected_local_images(targets : Array(CLI::TargetSelector::Target)?) : Array(String)
        selected_roles(targets).map { |role| @config.servers[role]?.try(&.image) || @config.image }.uniq!.sort!
      end

      # Unreadable sources would abort deploy on its first host.
      private def check_local_files(targets : Array(CLI::TargetSelector::Target)?) : Array(ProbeResult)
        selected_file_sources(targets).map_with_index do |source, index|
          position = 50 + index
          if @local_file_probe.call(source)
            pass("local", "file:#{source}", position, "readable")
          else
            fail("local", "file:#{source}", position, "not found or unreadable")
          end
        end
      end

      private def selected_file_sources(targets : Array(CLI::TargetSelector::Target)?) : Array(String)
        return [] of String if @config.files.empty?

        roles = selected_roles(targets)
        sources = @config.files
          .select { |file_sync| roles.any? { |role| file_sync.applies_to?(role) } }
          .map(&.source)
        sources.uniq!
        sources.sort!
      end

      private def selected_roles(targets : Array(CLI::TargetSelector::Target)?) : Array(String)
        targets ? targets.map(&.role).uniq! : @config.servers.keys.to_a
      end

      private def validate_batch_settings! : Nil
        if @config.boot.limit < 1
          raise ArgumentError.new("boot.limit must be at least 1")
        end
      end

      private def host_contexts(targets : Array(CLI::TargetSelector::Target)?) : Array(HostContext)
        roles_by_host = Hash(String, Array(String)).new { |hash, host| hash[host] = [] of String }

        if targets
          targets.each { |target| roles_by_host[target.host] << target.role }
        else
          @config.servers.each do |role, server|
            server.hosts.each { |host| roles_by_host[host] << role }
          end
        end

        roles_by_host.map do |host, roles|
          roles.sort!
          HostContext.new(host: host, roles: roles)
        end.sort_by!(&.host)
      end

      private def check_host(host_context : HostContext) : Array(ProbeResult)
        results = [] of ProbeResult

        connectivity = check_connectivity(host_context.host, 0)
        results << connectivity
        return results unless connectivity.passed

        results << check_podman_version(host_context.host, 1)
        results << command_probe(
          host_context.host,
          "lingering",
          2,
          ["sh", "-lc", "loginctl show-user #{Process.quote_posix(@config.ssh.user)} | grep -q '^Linger=yes$'"],
          "enabled"
        )
        results << command_probe(
          host_context.host,
          "quadlet-dir",
          3,
          ["sh", "-lc", "test -d ~/.config/containers/systemd && test -w ~/.config/containers/systemd"],
          "writable"
        )

        transfer_tools.each_with_index do |tool, index|
          results << command_probe(
            host_context.host,
            "tool:#{tool}",
            10 + index,
            ["sh", "-lc", "command -v #{Process.quote_posix(tool)} >/dev/null"],
            "found"
          )
        end

        secret_names.each_with_index do |secret, index|
          results << command_probe(
            host_context.host,
            "secret:#{secret}",
            20 + index,
            ["podman", "secret", "inspect", secret],
            "present"
          )
        end

        if check_proxy?(host_context)
          results << check_caddy(host_context.host, 30)
          results << command_probe(
            host_context.host,
            "caddy-version",
            31,
            ["sh", "-lc", caddy_version_check],
            ">= 2.11.6"
          )
          results << command_probe(
            host_context.host,
            "caddy-admin",
            32,
            ["curl", "--silent", "--show-error", "--fail", "--unix-socket", Proxy::Manager::ADMIN_SOCKET, "http://localhost/config/"],
            "reachable"
          )
          results << command_probe(
            host_context.host,
            "caddy-config",
            33,
            ["podman", "exec", Proxy::Manager::PROXY_NAME, "caddy", "validate", "--config", "/config/Caddyfile", "--adapter", "caddyfile"],
            "valid"
          )
          results << check_proxy_network(host_context.host, 34)
          if proxy = @config.servers["web"]?.try(&.proxy)
            results << command_probe(
              host_context.host,
              "probe-image",
              35,
              ["podman", "image", "exists", proxy.healthcheck.probe_image],
              proxy.healthcheck.probe_image
            )
          end
          # Missing asset mounts cause 404s despite a successful deploy.
          if @config.assets
            results << command_probe(
              host_context.host,
              "caddy-assets",
              36,
              ["podman", "exec", Proxy::Manager::PROXY_NAME, "test", "-d", "/srv/assets"],
              "mounted"
            )
          end
        end

        results << same_host_readiness(host_context.host, 40)

        # Both manifest checks use the same host state.
        manifests =
          begin
            run_ssh(host_context.host, Runtime::ServiceManifest.list_command, batch_mode: true)
          rescue ex : SSH::ConnectionError
            SSH::Result.new(exit_code: 1, stdout: "", stderr: ex.message || "manifest listing failed")
          end
        results << check_manifest_collisions(host_context.host, 41, manifests)
        results.concat(accessory_networks_probes(host_context.host))
        results.concat(shared_accessory_probes(host_context.host, manifests))
        results.concat(accessory_readiness_probes(host_context.host))
        results << check_proxy_sockets(host_context.host, 39) if check_proxy?(host_context)
        # Runs last, renders at position 4 next to the ssh row.
        results << check_ssh_units(host_context.host, 4)

        results
      end

      # Match deploy dependencies, including accessories without a host.
      private def co_network_accessories : Hash(String, Config::AccessoryConfig)
        @config.dependent_accessories
      end

      # Resolve every dependency locally, even if it has no host to probe.
      private def check_accessory_readiness_resolution : Array(ProbeResult)
        accessories = co_network_accessories
        accessories.keys.sort!.map_with_index do |name, index|
          position = 100 + index
          probe = "accessory-readiness:#{name}"
          begin
            ready = accessories[name].effective_ready(name)
            pass("local", probe, position, ready.summary)
          rescue ex : Config::ValidationError
            fail("local", probe, position, ex.message || "unresolved readiness")
          end
        end
      end

      # Podman networks are host-local, so every checked host running the app
      # needs each accessory network the app joins to exist there.
      private def accessory_networks_probes(host : String) : Array(ProbeResult)
        accessory_by_network = {} of String => String
        @config.dependent_accessories.each do |name, accessory|
          network = accessory.network_name
          next if network.nil? || @config.generated_network?(network)

          accessory_by_network[network] ||= name
        end

        accessory_by_network.keys.sort!.map_with_index do |network, index|
          accessory_network_probe(host, network, accessory_by_network[network], 42 + index)
        end
      end

      private def accessory_network_probe(host : String, network : String, accessory : String, position : Int32) : ProbeResult
        result = run_ssh(host, Runtime::ServiceNetwork.network_exists_command(network), batch_mode: true)
        return pass(host, "network:#{network}", position, "exists") if result.exit_code.zero?

        fail(host, "network:#{network}", position, "network does not exist; run `meridian accessory start #{accessory}`")
      rescue ex : SSH::ConnectionError
        fail(host, "network:#{network}", position, ex.message || "network check failed")
      end

      # Different definitions would overwrite another service's accessory.
      private def shared_accessory_probes(host : String, result : SSH::Result) : Array(ProbeResult)
        accessories = (@config.accessories || EMPTY_ACCESSORIES).select { |_, accessory| accessory.host == host }
        return [] of ProbeResult if accessories.empty?

        current = Runtime::ServiceManifest.from_config(@config)
        others =
          if result.exit_code.zero?
            Runtime::ServiceManifest.parse_all(result.stdout).reject { |manifest| manifest.service == @config.service }
          else
            [] of Runtime::ServiceManifest
          end

        accessories.keys.sort!.map_with_index do |name, index|
          position = 60 + index
          probe = "accessory:#{name}"
          conflicting = current.services_conflicting(name, others)

          if conflicting.empty?
            shared = current.services_sharing(name, others)
            detail = shared.empty? ? "definition matches" : "shared with #{shared.join(", ")}"
            pass(host, probe, position, detail)
          else
            fail(host, probe, position, "conflicts with service #{conflicting.join(", ")}")
          end
        end
      rescue ex : JSON::ParseException
        [fail(host, "accessory", 60, "invalid manifest: #{ex.message}")]
      rescue ex : SSH::ConnectionError
        [fail(host, "accessory", 60, ex.message || "accessory check failed")]
      end

      private def accessory_readiness_probes(host : String) : Array(ProbeResult)
        accessories = co_network_accessories.select { |_, accessory| accessory.host == host }
        names = accessories.keys.sort!

        names.map_with_index do |name, index|
          accessory = accessories[name]
          position = 50 + index
          probe = "accessory-readiness:#{name}"
          begin
            ready = accessory.effective_ready(name)
            network = accessory.network_name || @config.service
            command_probe(host, probe, position, accessory_probe_argv(name, ready, network), ready.summary)
          rescue ex : Config::ValidationError
            fail(host, probe, position, ex.message || "unresolved readiness")
          end
        end
      end

      private def accessory_probe_argv(
        name : String,
        ready : Config::AccessoryReadinessConfig,
        network : String,
      ) : Array(String)
        probe_image = Config::HealthcheckConfig::DEFAULT_PROBE_IMAGE

        if tcp = ready.tcp
          checks = tcp.map { |port| "nc -z #{name} #{port}" }.join(" && ")
          ["podman", "run", "--rm", "--network=#{network}", probe_image, "sh", "-c", checks]
        elsif http = ready.http
          ["podman", "run", "--rm", "--network=#{network}", probe_image, "wget", "-q", "-O-", "http://#{name}:#{http.port}#{http.path}"]
        elsif cmd = ready.cmd
          ["podman", "exec", name] + cmd
        else
          ["false"]
        end
      end

      private def check_connectivity(host : String, position : Int32) : ProbeResult
        result = run_ssh(host, ["true"], batch_mode: true)
        return pass(host, "ssh", position, "connected") if result.exit_code.zero?

        fail(host, "ssh", position, failure_detail(result))
      rescue ex : SSH::ConnectionError
        fail(host, "ssh", position, ex.message || "connection failed")
      end

      private def check_podman_version(host : String, position : Int32) : ProbeResult
        result = run_ssh(host, ["podman", "--version"], batch_mode: true)
        return fail(host, "podman", position, failure_detail(result)) unless result.exit_code.zero?

        version = parse_podman_version(result.stdout)
        return fail(host, "podman", position, "could not parse version: #{compact(result.stdout)}") unless version

        if supported_podman_version?(version)
          pass(host, "podman", position, version.label)
        else
          fail(host, "podman", position, "#{version.label} < #{MIN_PODMAN_MAJOR}.#{MIN_PODMAN_MINOR}")
        end
      rescue ex : SSH::ConnectionError
        fail(host, "podman", position, ex.message || "podman version check failed")
      end

      SSH_UNITS = %w[ssh.socket ssh.service sshd.socket sshd.service]

      # An orphaned sshd can accept connections but will not recover on failure.
      private def check_ssh_units(host : String, position : Int32) : ProbeResult
        result = run_ssh(host, ["sh", "-lc", ssh_units_check], batch_mode: true)
        states = result.stdout.lines.map(&.strip).reject(&.empty?)
        active = states.select(&.ends_with?("=active"))

        return pass(host, "ssh-units", position, active.join(" ")) if active.present?

        detail = states.present? ? states.join(" ") : failure_detail(result)
        fail(host, "ssh-units", position, "#{detail} - port 22 is served by an unmanaged process")
      rescue ex : SSH::ConnectionError
        fail(host, "ssh-units", position, ex.message || "ssh unit check failed")
      end

      private def ssh_units_check : String
        "for u in #{SSH_UNITS.join(' ')}; do printf '%s=%s\\n' \"$u\" \"$(systemctl is-active \"$u\" 2>/dev/null)\"; done"
      end

      private def check_caddy(host : String, position : Int32) : ProbeResult
        result = run_ssh(
          host,
          ["podman", "inspect", "--format", "{{.State.Running}}", Proxy::Manager::PROXY_NAME],
          batch_mode: true
        )
        return fail(host, "caddy", position, failure_detail(result)) unless result.exit_code.zero?

        result.stdout.strip == "true" ? pass(host, "caddy", position, "running") : fail(host, "caddy", position, "not running")
      rescue ex : SSH::ConnectionError
        fail(host, "caddy", position, ex.message || "Caddy check failed")
      end

      private def check_proxy_sockets(host : String, position : Int32) : ProbeResult
        proxy = @config.resolved_proxy
        command = <<-SH
          set -eu
          command -v ss >/dev/null
          start=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)
          [ #{proxy.http_port} -ge "$start" ] && [ #{proxy.https_port} -ge "$start" ] || { echo "unprivileged port threshold $start exceeds proxy ports"; exit 1; }
          systemctl --user is-active --quiet meridian-caddy.socket
          bindings=$(systemctl --user show meridian-caddy.socket --property=Listen --value)
          for binding in ":#{proxy.http_port} (Stream)" ":#{proxy.https_port} (Stream)" ":#{proxy.https_port} (Datagram)"; do
            case "$bindings" in *"$binding"*) ;; *) echo "socket unit missing $binding"; exit 1;; esac
          done
          pid=$(podman inspect --format '{{.State.Pid}}' meridian-caddy)
          case "$pid" in ''|0|*[!0-9]*) echo "missing Caddy process"; exit 1;; esac
          # Caddy's inherited FDs are visible even when systemd's are hidden.
          check_listener() {
            listeners=$(ss -H "$1" "sport = :$2")
            case "$listeners" in
              *rootlessport*) echo "rootlessport on $4 $2 loses client IPs"; exit 1;;
            esac
            case "$listeners" in
              *"pid=$pid,fd=$3)"*) ;;
              *) echo "$4 $2: missing Caddy activation FD $3 or process visibility"; exit 1;;
            esac
          }
          check_listener -lntp #{proxy.http_port} 3 TCP
          check_listener -lntp #{proxy.https_port} 4 TCP
          check_listener -lnup #{proxy.https_port} 5 UDP
          SH
        result = run_ssh(host, ["sh", "-lc", command], batch_mode: true)
        return pass(host, "caddy-sockets", position, "systemd TCP #{proxy.http_port}/#{proxy.https_port}, UDP #{proxy.https_port}") if result.exit_code.zero?

        fail(host, "caddy-sockets", position, "#{failure_detail(result)}; run meridian setup after correcting proxy prerequisites")
      rescue ex : SSH::ConnectionError
        fail(host, "caddy-sockets", position, ex.message || "socket check failed")
      end

      private def caddy_version_check : String
        Proxy::Manager::VERSION_CHECK
      end

      private def check_proxy_network(host : String, position : Int32) : ProbeResult
        result = run_ssh(
          host,
          ["podman", "network", "exists", Runtime::Paths::SHARED_PROXY_NETWORK],
          batch_mode: true
        )
        return pass(host, "proxy-network", position, Runtime::Paths::SHARED_PROXY_NETWORK) if result.exit_code.zero?

        fail(host, "proxy-network", position, failure_detail(result))
      rescue ex : SSH::ConnectionError
        fail(host, "proxy-network", position, ex.message || "proxy network check failed")
      end

      private def same_host_readiness(host : String, position : Int32) : ProbeResult
        manifest = Runtime::ServiceManifest.from_config(@config)
        route_summary = manifest.proxy_routes.empty? ? "routes=(none)" : "routes=#{manifest.proxy_routes.map(&.display).join(",")}"
        detail = "service=#{@config.service} state=#{Runtime::Paths.service_directory(@config.service)} proxy_network=#{Runtime::Paths::SHARED_PROXY_NETWORK} #{route_summary}"
        pass(host, "same-host", position, detail)
      end

      private def check_manifest_collisions(host : String, position : Int32, result : SSH::Result) : ProbeResult
        return fail(host, "manifest-collisions", position, failure_detail(result)) unless result.exit_code.zero?

        current = Runtime::ServiceManifest.from_config(@config)
        collisions = Runtime::ServiceManifest.parse_all(result.stdout).flat_map { |manifest| current.collisions_with(manifest) }

        if collisions.empty?
          pass(host, "manifest-collisions", position, "none")
        else
          fail(host, "manifest-collisions", position, compact(collisions.join("; ")))
        end
      rescue ex : JSON::ParseException
        fail(host, "manifest-collisions", position, "invalid manifest: #{ex.message}")
      rescue ex : SSH::ConnectionError
        fail(host, "manifest-collisions", position, ex.message || "manifest collision check failed")
      end

      private def command_probe(
        host : String,
        name : String,
        position : Int32,
        command : Array(String),
        success_detail : String,
      ) : ProbeResult
        result = run_ssh(host, command, batch_mode: true)
        return pass(host, name, position, success_detail) if result.exit_code.zero?

        fail(host, name, position, failure_detail(result))
      rescue ex : SSH::ConnectionError
        fail(host, name, position, ex.message || "#{name} check failed")
      end

      private def parse_podman_version(output : String) : PodmanVersion?
        return unless match = /(\d+)\.(\d+)(?:\.\d+)?/.match(output)

        PodmanVersion.new(
          major: match[1].to_i,
          minor: match[2].to_i,
          label: match[0]
        )
      end

      private def supported_podman_version?(version : PodmanVersion) : Bool
        version.major > MIN_PODMAN_MAJOR ||
          (version.major == MIN_PODMAN_MAJOR && version.minor >= MIN_PODMAN_MINOR)
      end

      private def transfer_tools : Array(String)
        mode = @config.transfer.try(&.mode)
        return [] of String if mode.nil? || mode.registry?
        return ["zstd"] if mode.stream?

        ["zstd", "rsync", "skopeo"]
      end

      # Match transfer classes: incremental uses rsync locally, skopeo remotely.
      private def local_transfer_tools : Array(String)
        mode = @config.transfer.try(&.mode)
        return [] of String if mode.nil? || mode.registry?
        return ["zstd"] if mode.stream?

        ["rsync"]
      end

      private def secret_names : Array(String)
        names = (@config.env.try(&.secret) || [] of String).dup
        names.uniq!
        names.sort!
        names
      end

      private def check_proxy?(host_context : HostContext) : Bool
        return false unless host_context.roles.includes?("web")

        !!@config.servers["web"]?.try(&.proxy)
      end

      private def pass(host : String, probe : String, position : Int32, detail : String) : ProbeResult
        ProbeResult.new(host: host, probe: probe, position: position, passed: true, detail: detail)
      end

      private def fail(host : String, probe : String, position : Int32, detail : String) : ProbeResult
        ProbeResult.new(host: host, probe: probe, position: position, passed: false, detail: detail)
      end

      private def failure_detail(result : SSH::Result) : String
        detail = compact("#{result.stdout}\n#{result.stderr}")
        detail.empty? ? "exit #{result.exit_code}" : "exit #{result.exit_code}: #{detail}"
      end

      private def compact(value : String) : String
        text = value.lines.map(&.strip).reject(&.empty?).join(" ")
        return text if text.size <= 120

        "#{text[0, 117]}..."
      end

      private def print_rows(rows : Array(ProbeResult)) : Nil
        sorted_rows = rows.sort_by { |row| {row.host, row.position, row.probe} }

        host_width = Math.max("host".size, sorted_rows.max_of?(&.host.size) || 0)
        probe_width = Math.max("probe".size, sorted_rows.max_of?(&.probe.size) || 0)
        status_width = "status".size

        @output.puts [
          pad("host", host_width),
          pad("probe", probe_width),
          pad("status", status_width),
          "detail",
        ].join("  ")

        sorted_rows.each do |row|
          @output.puts [
            pad(row.host, host_width),
            pad(row.probe, probe_width),
            pad(row.passed ? "ok" : "fail", status_width),
            row.detail,
          ].join("  ")
        end
      end

      private def pad(value : String, width : Int32) : String
        value.ljust(width)
      end
    end
  end
end
