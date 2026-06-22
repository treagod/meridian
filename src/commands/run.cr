module Meridian
  module Commands
    class Run < Base
      def run(role : String, command : Array(String), host : String? = nil) : Int32
        role_hosts = hosts_for_role(role)
        target_host = resolve_host(role, role_hosts, host)
        require_service_network!(target_host, "meridian run")

        cmd = ["podman", "run", "--rm", "--network", service_network_name]

        if env = @config.env
          env.clear.each { |k, v| cmd << "--env" << "#{k}=#{v}" }
          env.secret.each { |secret| cmd << "--secret" << "#{secret},type=env,target=#{secret}" }
        end

        cmd << @config.image
        cmd.concat(command)

        stream_ssh(target_host, cmd)
      end

      private def resolve_host(role : String, role_hosts : Array(String), host : String?) : String
        return role_hosts.first unless host
        return host if role_hosts.includes?(host)

        raise ArgumentError.new("Host #{host} is not configured for role: #{role}")
      end
    end
  end
end
