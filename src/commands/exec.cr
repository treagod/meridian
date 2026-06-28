module Meridian
  module Commands
    class Exec < Base
      def run(role : String, command : Array(String), host : String? = nil) : Int32
        role_hosts = hosts_for_role(role)
        target_host = resolve_host(role, role_hosts, host)
        server = server_config(role)
        unless server.managed?
          raise ArgumentError.new("exec is not supported for unmanaged role: #{role}")
        end

        container_name =
          if server.proxy
            service_name(running_color_for(target_host))
          else
            role_service_name(role)
          end

        stream_ssh(
          target_host,
          ["podman", "exec", "-i", container_name] + command
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
