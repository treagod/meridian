module Meridian
  module Commands
    class Status < Base
      private record Row,
        role : String,
        host : String,
        release : String,
        deployment : String,
        state : String

      def run(targets : Array(CLI::TargetSelector::Target)? = nil) : Nil
        pairs = role_host_pairs(targets)

        rows = pairs.sort_by { |role, host| {role, host} }.map do |role, host|
          status_row(role, host)
        end

        role_width = Math.max("role".size, rows.max_of?(&.role.size) || 0)
        host_width = Math.max("host".size, rows.max_of?(&.host.size) || 0)
        release_width = Math.max("release".size, rows.max_of?(&.release.size) || 0)
        deployment_width = Math.max("deployment".size, rows.max_of?(&.deployment.size) || 0)
        state_width = Math.max("state".size, rows.max_of?(&.state.size) || 0)

        @output.puts [
          pad("role", role_width),
          pad("host", host_width),
          pad("release", release_width),
          pad("deployment", deployment_width),
          pad("state", state_width),
        ].join("  ")

        rows.each do |row|
          @output.puts [
            pad(row.role, role_width),
            pad(row.host, host_width),
            pad(row.release, release_width),
            pad(row.deployment, deployment_width),
            pad(row.state, state_width),
          ].join("  ")
        end
      rescue ex : Config::UnknownRole | ArgumentError
        raise ex
      end

      private def role_host_pairs(targets : Array(CLI::TargetSelector::Target)?) : Array({String, String})
        return all_role_hosts unless targets

        targets.map { |target| {target.role, target.host} }
      end

      private def release_label(host : String) : String
        read_release_state(host).try(&.current.release_id) || "-"
      end

      private def status_row(role : String, host : String) : Row
        server = server_config(role)

        unless server.managed?
          return Row.new(
            role: role,
            host: host,
            release: "-",
            deployment: "existing",
            state: unit_states(host, server.units)
          )
        end

        if server.proxy
          Row.new(
            role: role,
            host: host,
            release: release_label(host),
            deployment: "blue/green",
            state: "blue=#{unit_state(host, service_unit(Quadlet::Color::Blue))},green=#{unit_state(host, service_unit(Quadlet::Color::Green))}"
          )
        else
          unit = role_service_unit(role)
          Row.new(
            role: role,
            host: host,
            release: "-",
            deployment: unit,
            state: unit_state(host, unit)
          )
        end
      end

      private def unit_states(host : String, units : Array(String)) : String
        units.map { |unit| "#{unit}=#{unit_state(host, unit)}" }.join(",")
      end

      private def unit_state(host : String, unit : String) : String
        result = run_ssh(
          host,
          ["systemctl", "--user", "status", unit, "--no-pager", "--lines", "0"]
        )
        summarize_state(result)
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to inspect service state for #{host}")
      end

      private def summarize_state(result : SSH::Result) : String
        combined = "#{result.stdout}\n#{result.stderr}".downcase

        return "active" if result.exit_code.zero?
        return "missing" if combined.includes?("could not be found") || combined.includes?("not-found")
        return "failed" if combined.includes?("active: failed") || combined.includes?("failed")

        "inactive"
      end

      private def pad(value : String, width : Int32) : String
        value.ljust(width)
      end
    end
  end
end
