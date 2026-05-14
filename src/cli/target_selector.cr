module Meridian
  module CLI
    class TargetSelector
      record Target, role : String, host : String

      property role : String? = nil
      property host : String? = nil
      property? primary : Bool = false

      def register(parser : OptionParser, *,
                   role : Bool = true,
                   host : Bool = true,
                   primary : Bool = true) : Nil
        parser.on("--role ROLE", "Limit to a configured role") { |value| @role = value } if role
        parser.on("--host HOST", "Limit to a configured host") { |value| @host = value } if host
        parser.on("--primary", "Limit to the primary host (first web host)") { @primary = true } if primary
      end

      def empty? : Bool
        @role.nil? && @host.nil? && !@primary
      end

      def resolve(config : Config::DeployConfig) : Array(Target)
        validate_flag_combination!

        if primary?
          return [primary_target(config)]
        end

        if (role = @role) && (host = @host)
          [validated_pair(config, role, host)]
        elsif role = @role
          role_targets(config, role)
        elsif host = @host
          host_targets(config, host)
        else
          all_targets(config)
        end
      end

      private def validate_flag_combination! : Nil
        return unless primary?

        raise ArgumentError.new("--primary cannot be combined with --host") if @host
        raise ArgumentError.new("--primary cannot be combined with --role") if @role
      end

      private def primary_target(config : Config::DeployConfig) : Target
        server = config.servers["web"]?
        raise ArgumentError.new("--primary requires a 'web' role") unless server
        host = server.hosts.first?
        raise ArgumentError.new("--primary requires the 'web' role to have at least one host") unless host

        Target.new(role: "web", host: host)
      end

      private def validated_pair(config : Config::DeployConfig, role : String, host : String) : Target
        server = config.servers[role]? || raise unknown_role(config, role)
        raise host_not_in_role(role, host, server.hosts) unless server.hosts.includes?(host)

        Target.new(role: role, host: host)
      end

      private def role_targets(config : Config::DeployConfig, role : String) : Array(Target)
        server = config.servers[role]? || raise unknown_role(config, role)
        server.hosts.map { |host| Target.new(role: role, host: host) }
      end

      private def host_targets(config : Config::DeployConfig, host : String) : Array(Target)
        targets = [] of Target
        config.servers.each do |role, server|
          targets << Target.new(role: role, host: host) if server.hosts.includes?(host)
        end
        raise unknown_host(config, host) if targets.empty?

        targets
      end

      private def all_targets(config : Config::DeployConfig) : Array(Target)
        targets = [] of Target
        config.servers.each do |role, server|
          server.hosts.each { |host| targets << Target.new(role: role, host: host) }
        end
        targets
      end

      private def unknown_role(config : Config::DeployConfig, role : String) : ArgumentError
        valid = config.servers.keys.join(", ")
        ArgumentError.new("Unknown role: #{role}. Valid roles: #{valid}")
      end

      private def unknown_host(config : Config::DeployConfig, host : String) : ArgumentError
        hosts = config.servers.flat_map { |_, server| server.hosts }
        hosts.uniq!
        ArgumentError.new("Unknown host: #{host}. Valid hosts: #{hosts.join(", ")}")
      end

      private def host_not_in_role(role : String, host : String, role_hosts : Array(String)) : ArgumentError
        valid = role_hosts.join(", ")
        ArgumentError.new("Host #{host} is not configured for role: #{role}. Valid hosts: #{valid}")
      end
    end
  end
end
