module Meridian
  module Deploy
    class Orchestrator
      DEFAULT_COLOR     = Quadlet::Color::Green
      ACTIVE_COLOR_FILE = File.join(Quadlet::DIRECTORY, ".meridian-color")

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        @output : IO = STDOUT,
      )
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(@config)
      end

      def deploy_to_host(
        host : String,
        role : String,
        color : Quadlet::Color = DEFAULT_COLOR,
      ) : Nil
        server = server_config(role)
        service_name = service_name(color)
        service_unit = service_unit(color)
        container_file = @quadlet_generator.container_file(server, color)

        log(host, "Pulling image #{@config.image}")
        @ssh_executor.run!(host, ["podman", "pull", @config.image])

        log(host, "Ensuring Quadlet directory exists")
        @ssh_executor.run!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading network Quadlet")
        @ssh_executor.upload(host, network_path, @quadlet_generator.network_file)

        log(host, "Uploading service Quadlet")
        @ssh_executor.upload(host, container_path(color), container_file)

        log(host, "Reloading user systemd")
        @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])

        active_service = @ssh_executor.run(host, ["systemctl", "--user", "is-active", service_unit])
        if active_service.exit_code.zero?
          log(host, "Stopping existing service #{service_unit}")
          @ssh_executor.run!(host, ["systemctl", "--user", "stop", service_unit])
        end

        log(host, "Starting service #{service_unit}")
        @ssh_executor.run!(host, ["systemctl", "--user", "start", service_unit])
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Deploy to #{host} failed")
      end

      def zero_downtime_deploy_to_host(host : String, role : String) : Nil
        server = server_config(role)
        proxy = server.proxy || raise DeployFailed.new("Missing proxy configuration for role: #{role}")
        old_color = current_color_for(host)
        old_active = service_active?(host, old_color)
        new_color = inactive_color(old_color)
        new_service = service_name(new_color)

        log(host, "Pulling image #{@config.image}")
        @ssh_executor.run!(host, ["podman", "pull", @config.image])

        log(host, "Ensuring Quadlet directory exists")
        @ssh_executor.run!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading network Quadlet")
        @ssh_executor.upload(host, network_path, @quadlet_generator.network_file)

        log(host, "Uploading service Quadlet")
        @ssh_executor.upload(host, container_path(new_color), @quadlet_generator.container_file(server, new_color))

        log(host, "Reloading user systemd")
        @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Starting service #{service_unit(new_color)}")
        @ssh_executor.run!(host, ["systemctl", "--user", "start", service_unit(new_color)])

        begin
          log(host, "Checking health for #{new_service}")
          health_checker_for(host).poll(
            healthcheck_url(host, proxy, new_service),
            interval: proxy.healthcheck.interval.seconds,
            timeout: proxy.healthcheck.timeout.seconds,
            retries: proxy.healthcheck.retries
          )

          log(host, "Switching proxy traffic to #{new_service}")
          @ssh_executor.run!(host, proxy_deploy_command(proxy, new_color))
        rescue ex : Health::CheckFailed | SSH::CommandFailed | SSH::ConnectionError
          cleanup_failed_candidate(host, new_color)
          raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
        end

        if old_active
          log(host, "Stopping service #{service_unit(old_color)}")
          @ssh_executor.run!(host, ["systemctl", "--user", "stop", service_unit(old_color)])
        end

        log(host, "Removing inactive Quadlet #{container_path(old_color)}")
        @ssh_executor.run!(host, ["rm", "-f", container_path(old_color)])

        log(host, "Reloading user systemd")
        @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Recording active color #{new_color.slug}")
        @ssh_executor.upload(host, ACTIVE_COLOR_FILE, "#{new_color.slug}\n")

        log(host, "Pruning unused images")
        prune_result = @ssh_executor.run(host, ["podman", "image", "prune", "-f"])
        unless prune_result.exit_code.zero?
          log(host, "Image prune failed with exit code #{prune_result.exit_code}")
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
      end

      def deploy : Nil
        web_server = server_config("web")
        host = web_server.hosts.first? || raise DeployFailed.new("No hosts configured for role: web")

        @output.puts "Deploying #{@config.service} to #{host}"
        if web_server.proxy
          zero_downtime_deploy_to_host(host, "web")
        else
          deploy_to_host(host, "web")
        end
        @output.puts "Deploy completed on #{host}"
      end

      private def service_name(color : Quadlet::Color) : String
        "#{@config.service}-#{color.slug}"
      end

      private def service_unit(color : Quadlet::Color) : String
        "#{service_name(color)}.service"
      end

      private def container_path(color : Quadlet::Color) : String
        File.join(Quadlet::DIRECTORY, "#{service_name(color)}.container")
      end

      private def network_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}.network")
      end

      private def server_config(role : String) : Config::ServerConfig
        @config.servers[role]? || raise Config::UnknownRole.new("Unknown role: #{role}")
      end

      private def inactive_color(color : Quadlet::Color) : Quadlet::Color
        case color
        in .blue?
          Quadlet::Color::Green
        in .green?
          Quadlet::Color::Blue
        end
      end

      private def current_color_for(host : String) : Quadlet::Color
        stored_color = stored_active_color(host)
        return stored_color if stored_color

        blue_active = service_active?(host, Quadlet::Color::Blue)
        green_active = service_active?(host, Quadlet::Color::Green)

        if blue_active && green_active
          raise DeployFailed.new("Cannot determine active color for #{host}: both colors are active")
        end

        return Quadlet::Color::Blue if blue_active
        return Quadlet::Color::Green if green_active

        Quadlet::Color::Blue
      end

      private def stored_active_color(host : String) : Quadlet::Color?
        result = @ssh_executor.run(host, ["cat", ACTIVE_COLOR_FILE])
        return unless result.exit_code.zero?

        color_name = result.stdout.strip
        return if color_name.empty?

        Quadlet::Color.parse?(color_name) || raise DeployFailed.new("Invalid active color stored on #{host}: #{color_name}")
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to read active color for #{host}")
      end

      private def service_active?(host : String, color : Quadlet::Color) : Bool
        @ssh_executor.run(host, ["systemctl", "--user", "is-active", service_unit(color)]).exit_code.zero?
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect service state for #{host}")
      end

      private def health_checker_for(host : String) : Health::Checker
        Health::Checker.new(
          output: @output,
          transport: Health::SSHTransport.new(host, @ssh_executor)
        )
      end

      private def healthcheck_url(
        host : String,
        proxy : Config::ServerProxyConfig,
        container_name : String,
      ) : String
        ip_result = @ssh_executor.run!(
          host,
          [
            "podman",
            "inspect",
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            container_name,
          ]
        )
        container_ip = ip_result.stdout.strip
        raise DeployFailed.new("Could not determine container IP for #{container_name} on #{host}") if container_ip.empty?

        "http://#{container_ip}:#{proxy.app_port}#{proxy.healthcheck.path}"
      end

      private def proxy_deploy_command(
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

      private def cleanup_failed_candidate(host : String, color : Quadlet::Color) : Nil
        log(host, "Cleaning up failed candidate #{service_name(color)}")
        @ssh_executor.run(host, ["systemctl", "--user", "stop", service_unit(color)])
        @ssh_executor.run(host, ["rm", "-f", container_path(color)])
        @ssh_executor.run(host, ["systemctl", "--user", "daemon-reload"])
      rescue ex : SSH::ConnectionError
        log(host, "Cleanup failed: #{ex.message || ex.class.name}")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
