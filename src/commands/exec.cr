module Meridian
  module Commands
    class Exec < Base
      def run(role : String, command : Array(String), host : String? = nil) : Int32
        role_hosts = hosts_for_role(role)
        target_host = resolve_host(role, role_hosts, host)
        color = running_color_for(target_host)

        stream_ssh(
          target_host,
          ["podman", "exec", "-i", service_name(color)] + command
        )
      end

      private def resolve_host(role : String, role_hosts : Array(String), host : String?) : String
        return role_hosts.first unless host
        return host if role_hosts.includes?(host)

        raise ArgumentError.new("Host #{host} is not configured for role: #{role}")
      end
    end
  end
end
