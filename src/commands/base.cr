module Meridian
  module Commands
    abstract class Base
      ACTIVE_COLOR_FILE = File.join(Quadlet::DIRECTORY, ".meridian-color")

      protected getter config : Config::DeployConfig
      protected getter output : IO
      protected getter error : IO

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        @output : IO = STDOUT,
        @error : IO = STDERR,
      )
      end

      protected def service_name(color : Quadlet::Color) : String
        "#{@config.service}-#{color.slug}"
      end

      protected def service_unit(color : Quadlet::Color) : String
        "#{service_name(color)}.service"
      end

      protected def inactive_color(color : Quadlet::Color) : Quadlet::Color
        case color
        in .blue?
          Quadlet::Color::Green
        in .green?
          Quadlet::Color::Blue
        end
      end

      protected def server_config(role : String) : Config::ServerConfig
        @config.servers[role]? || raise Config::UnknownRole.new("Unknown role: #{role}")
      end

      protected def hosts_for_role(role : String) : Array(String)
        hosts = server_config(role).hosts
        raise ArgumentError.new("No hosts configured for role: #{role}") if hosts.empty?

        hosts
      end

      protected def all_role_hosts : Array({String, String})
        @config.servers.flat_map do |role, server|
          server.hosts.map { |host| {role, host} }
        end
      end

      protected def all_hosts : Array(String)
        hosts = all_role_hosts.map(&.[1])
        hosts.uniq!
        hosts
      end

      protected def run_ssh(host : String, command : Array(String), *, batch_mode : Bool = false) : SSH::Result
        @ssh_executor.run(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval,
          batch_mode: batch_mode
        )
      end

      protected def run_ssh!(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run!(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      protected def run_ssh!(host : String, command : Array(String), input : String) : SSH::Result
        @ssh_executor.run!(
          host,
          command,
          input: input,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      protected def stream_ssh(
        host : String,
        command : Array(String),
        *,
        input : IO = STDIN,
        output : IO = @output,
        error : IO = @error,
      ) : Int32
        @ssh_executor.stream(
          host,
          command,
          input: input,
          output: output,
          error: error,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      protected def upload_ssh(host : String, remote_path : String, content : String) : Nil
        @ssh_executor.upload(
          host,
          remote_path,
          content,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      protected def stored_active_color(host : String) : Quadlet::Color?
        result = run_ssh(host, ["cat", ACTIVE_COLOR_FILE])
        return unless result.exit_code.zero?

        color_name = result.stdout.strip
        return if color_name.empty?

        Quadlet::Color.parse?(color_name) || raise ArgumentError.new("Invalid active color stored on #{host}: #{color_name}")
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to read active color for #{host}")
      end

      protected def running_color_for(host : String) : Quadlet::Color
        if color = stored_active_color(host)
          return color if container_running?(host, service_name(color))
        end

        blue_active = service_active?(host, Quadlet::Color::Blue)
        green_active = service_active?(host, Quadlet::Color::Green)

        if blue_active && green_active
          raise ArgumentError.new("Cannot determine active color for #{host}: both colors are active")
        end

        return Quadlet::Color::Blue if blue_active
        return Quadlet::Color::Green if green_active

        raise ArgumentError.new("Cannot determine active color for #{host}: no running color found")
      end

      protected def service_active?(host : String, color : Quadlet::Color) : Bool
        run_ssh(host, ["systemctl", "--user", "is-active", service_unit(color)]).exit_code.zero?
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to inspect service state for #{host}")
      end

      protected def accessory_config(name : String) : Config::AccessoryConfig
        accessories = @config.accessories || raise Config::UnknownAccessory.new("Unknown accessory: #{name}")
        accessories[name]? || raise Config::UnknownAccessory.new("Unknown accessory: #{name}")
      end

      protected def accessory_host(name : String, accessory : Config::AccessoryConfig) : String
        host = accessory.host.to_s.strip
        raise ArgumentError.new("Accessory #{name} is missing required host") if host.empty?

        host
      end

      protected def accessory_quadlet_path(name : String) : String
        File.join(Quadlet::DIRECTORY, "#{name}.container")
      end

      protected def accessory_service_unit(name : String) : String
        "#{name}.service"
      end

      protected def container_exists?(host : String, container_name : String) : Bool
        run_ssh(host, ["podman", "container", "exists", container_name]).exit_code.zero?
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to inspect container state for #{host}")
      end

      protected def container_running?(host : String, container_name : String) : Bool
        result = run_ssh(host, ["podman", "inspect", "--format", "{{.State.Running}}", container_name])
        result.exit_code.zero? && result.stdout.strip == "true"
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to inspect container state for #{host}")
      end

      protected def proxy_deploy_command(
        proxy : Config::ServerProxyConfig,
        color : Quadlet::Color,
      ) : Array(String)
        command = [
          "podman",
          "exec",
          "kamal-proxy",
          "kamal-proxy",
          "deploy",
          @config.service,
          "--target",
          "#{service_name(color)}:#{proxy.app_port}",
          "--health-check-path",
          proxy.healthcheck.path,
          "--health-check-interval",
          "#{proxy.healthcheck.interval}s",
          "--health-check-timeout",
          "#{proxy.healthcheck.timeout}s",
        ]

        if host = proxy.host
          command << "--host"
          command << host
        end

        if proxy.ssl?
          command << "--tls"
        end

        if path = proxy.path
          command << "--path-prefix"
          command << path
        end

        command
      end

      protected def ssh_command_failed(host : String, exit_code : Int32) : SSH::CommandFailed
        SSH::CommandFailed.new("Remote command on #{target_host(host)} failed with exit code #{exit_code}")
      end

      private def ssh_user : String
        @config.ssh.user
      end

      private def ssh_port : Int32?
        port = @config.ssh.port
        port == 22 ? nil : port
      end

      private def ssh_identity_file : String?
        @config.ssh.keys.first?
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

      private def target_host(host : String) : String
        if user = ssh_user
          "#{user}@#{host}"
        else
          host
        end
      end
    end
  end
end
