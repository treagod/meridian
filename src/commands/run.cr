module Meridian
  module Commands
    class Run < Base
      def run(role : String, command : Array(String), host : String? = nil) : Int32
        role_hosts = hosts_for_role(role)
        target_host = resolve_host(role, role_hosts, host)

        cmd = ["podman", "run", "--rm", "--network", "#{@config.service}.network"]

        if env = @config.env
          env.clear.each { |k, v| cmd << "--env" << "#{k}=#{v}" }
          env.secret.each { |s| cmd << "--secret" << "#{s},type=env,target=#{s}" }
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
