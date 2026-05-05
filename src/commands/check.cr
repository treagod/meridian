module Meridian
  module Commands
    class Check < Base
      MIN_PODMAN_MAJOR = 4
      MIN_PODMAN_MINOR = 4

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

      def run : Bool
        validate_batch_settings!

        rows = [] of ProbeResult
        hosts = host_contexts
        raise ArgumentError.new("No hosts configured") if hosts.empty?

        remaining_hosts = hosts.dup
        until remaining_hosts.empty?
          batch = remaining_hosts.shift(@config.boot.limit)
          channel = Channel(Array(ProbeResult)).new(batch.size)

          batch.each do |host_context|
            spawn do
              channel.send(check_host(host_context))
            end
          end

          batch.size.times do
            rows.concat(channel.receive)
          end
        end

        print_rows(rows)
        passed = rows.all?(&.passed)
        @output.puts(passed ? "Check passed" : "Check failed")
        passed
      end

      private def validate_batch_settings! : Nil
        if @config.boot.limit < 1
          raise ArgumentError.new("boot.limit must be at least 1")
        end
      end

      private def host_contexts : Array(HostContext)
        roles_by_host = Hash(String, Array(String)).new { |hash, host| hash[host] = [] of String }

        @config.servers.each do |role, server|
          server.hosts.each do |host|
            roles_by_host[host] << role
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
          results << check_kamal_proxy(host_context.host, 30)
        end

        results
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

      private def check_kamal_proxy(host : String, position : Int32) : ProbeResult
        result = run_ssh(
          host,
          ["podman", "inspect", "--format", "{{.State.Running}}", "kamal-proxy"],
          batch_mode: true
        )
        return fail(host, "kamal-proxy", position, failure_detail(result)) unless result.exit_code.zero?

        result.stdout.strip == "true" ? pass(host, "kamal-proxy", position, "running") : fail(host, "kamal-proxy", position, "not running")
      rescue ex : SSH::ConnectionError
        fail(host, "kamal-proxy", position, ex.message || "kamal-proxy check failed")
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
