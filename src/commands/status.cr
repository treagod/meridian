module Meridian
  module Commands
    class Status < Base
      private record Row,
        role : String,
        host : String,
        blue : String,
        green : String

      def run : Nil
        rows = all_role_hosts.sort_by { |role, host| {role, host} }.map do |role, host|
          Row.new(
            role: role,
            host: host,
            blue: service_state(host, Quadlet::Color::Blue),
            green: service_state(host, Quadlet::Color::Green)
          )
        end

        role_width = Math.max("role".size, rows.max_of?(&.role.size) || 0)
        host_width = Math.max("host".size, rows.max_of?(&.host.size) || 0)
        blue_width = Math.max("blue".size, rows.max_of?(&.blue.size) || 0)
        green_width = Math.max("green".size, rows.max_of?(&.green.size) || 0)

        @output.puts [
          pad("role", role_width),
          pad("host", host_width),
          pad("blue", blue_width),
          pad("green", green_width),
        ].join("  ")

        rows.each do |row|
          @output.puts [
            pad(row.role, role_width),
            pad(row.host, host_width),
            pad(row.blue, blue_width),
            pad(row.green, green_width),
          ].join("  ")
        end
      rescue ex : Config::UnknownRole | ArgumentError
        raise ex
      end

      private def service_state(host : String, color : Quadlet::Color) : String
        result = run_ssh(
          host,
          ["systemctl", "--user", "status", service_unit(color), "--no-pager", "--lines", "0"]
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
