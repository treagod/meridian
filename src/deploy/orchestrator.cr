module Meridian
  module Deploy
    class Orchestrator
      DEFAULT_COLOR     = Quadlet::Color::Green
      ACTIVE_COLOR_FILE = File.join(Quadlet::DIRECTORY, ".meridian-color")

      private record HostDeployResult,
        role : String,
        host : String,
        error : DeployFailed?

      private record RoleDeployResult,
        role : String,
        error : DeployFailed?

      private class RolloutAbort
        @error : DeployFailed? = nil
        @mutex = Mutex.new

        def request(error : DeployFailed) : Nil
          @mutex.synchronize do
            @error ||= error
          end
        end

        def requested? : Bool
          @mutex.synchronize do
            !@error.nil?
          end
        end

        def error : DeployFailed?
          @mutex.synchronize do
            @error
          end
        end
      end

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        stream_transfer : Transfer::Stream? = nil,
        incremental_transfer : Transfer::Incremental? = nil,
        @output : IO = STDOUT,
        @batch_sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration },
        @hook_runner : Proc(String, Hash(String, String), Int32) = ->(script : String, env : Hash(String, String)) { Process.run(script, env: env, shell: true).exit_code },
      )
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(@config)
        @stream_transfer = stream_transfer || Transfer::Stream.new(
          @ssh_executor,
          output: @output,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
        @incremental_transfer = incremental_transfer || Transfer::Incremental.new(
          @config.service,
          @ssh_executor,
          output: @output,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      def deploy_to_host(
        host : String,
        role : String,
        color : Quadlet::Color = DEFAULT_COLOR,
      ) : Nil
        server = server_config(role)
        deployed_service_name = service_name(color)
        service_unit = service_unit(color)
        container_file = @quadlet_generator.container_file(server, color)

        transfer_image_to_host(host, server.image || @config.image)

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading network Quadlet")
        upload_ssh(host, network_path, @quadlet_generator.network_file)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, container_path(color), container_file)

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        active_service = run_ssh(host, ["systemctl", "--user", "is-active", service_unit])
        if active_service.exit_code.zero?
          log(host, "Stopping existing service #{service_unit}")
          run_ssh!(host, ["systemctl", "--user", "stop", service_unit])
        end

        log(host, "Starting service #{deployed_service_name}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit])
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

        transfer_image_to_host(host, server.image || @config.image)

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading network Quadlet")
        upload_ssh(host, network_path, @quadlet_generator.network_file)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, container_path(new_color), @quadlet_generator.container_file(server, new_color))

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Starting service #{service_unit(new_color)}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit(new_color)])

        begin
          log(host, "Checking health for #{new_service}")
          health_checker_for(host).poll(
            healthcheck_url(host, proxy, new_service),
            interval: proxy.healthcheck.interval.seconds,
            timeout: proxy.healthcheck.timeout.seconds,
            retries: proxy.healthcheck.retries
          )

          log(host, "Switching proxy traffic to #{new_service}")
          run_ssh!(host, proxy_deploy_command(proxy, new_color))
        rescue ex : Health::CheckFailed | SSH::CommandFailed | SSH::ConnectionError
          cleanup_failed_candidate(host, new_color)
          raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
        end

        if old_active
          log(host, "Stopping service #{service_unit(old_color)}")
          run_ssh!(host, ["systemctl", "--user", "stop", service_unit(old_color)])
        end

        log(host, "Removing inactive Quadlet #{container_path(old_color)}")
        run_ssh!(host, ["rm", "-f", container_path(old_color)])

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Recording active color #{new_color.slug}")
        upload_ssh(host, ACTIVE_COLOR_FILE, "#{new_color.slug}\n")

        log(host, "Pruning unused images")
        prune_result = run_ssh(host, ["podman", "image", "prune", "-f"])
        unless prune_result.exit_code.zero?
          log(host, "Image prune failed with exit code #{prune_result.exit_code}")
        end
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
      end

      def deploy : Nil
        validate_rollout_settings!
        validate_registry_credentials!
        run_pre_deploy_hook
        web_hosts = hosts_for_role("web")
        secondary_roles = ordered_secondary_roles
        abort_rollout = RolloutAbort.new
        secondary_results = Channel(RoleDeployResult).new
        secondary_started = false
        secondary_started_mutex = Mutex.new
        secondary_count = secondary_roles.size

        start_secondary_roles = -> do
          should_start = secondary_started_mutex.synchronize do
            if secondary_started
              false
            else
              secondary_started = true
            end
          end
          if should_start
            secondary_roles.each do |role|
              spawn do
                secondary_results.send(deploy_role(role, abort_rollout))
              end
            end
          end
        end

        @output.puts "Deploying #{@config.service} to #{web_hosts.size} web host#{web_hosts.size == 1 ? "" : "s"}"

        web_result = deploy_role("web", abort_rollout) do |_host|
          start_secondary_roles.call
        end

        if secondary_started
          secondary_count.times do
            role_result = secondary_results.receive
            if error = role_result.error
              abort_rollout.request(error)
            end
          end
        end

        if error = abort_rollout.error
          raise error
        end

        if error = web_result.error
          raise error
        end

        @output.puts "Deploy completed"
        run_post_deploy_hook
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
        result = run_ssh(host, ["cat", ACTIVE_COLOR_FILE])
        return unless result.exit_code.zero?

        color_name = result.stdout.strip
        return if color_name.empty?

        Quadlet::Color.parse?(color_name) || raise DeployFailed.new("Invalid active color stored on #{host}: #{color_name}")
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to read active color for #{host}")
      end

      private def service_active?(host : String, color : Quadlet::Color) : Bool
        run_ssh(host, ["systemctl", "--user", "is-active", service_unit(color)]).exit_code.zero?
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect service state for #{host}")
      end

      private def health_checker_for(host : String) : Health::Checker
        Health::Checker.new(
          output: @output,
          transport: Health::SSHTransport.new(
            host,
            @ssh_executor,
            user: ssh_user,
            port: ssh_port,
            identity_file: ssh_identity_file,
            proxy_jump: ssh_proxy_jump,
            connect_timeout: ssh_connect_timeout,
            keepalive: ssh_keepalive,
            keepalive_interval: ssh_keepalive_interval
          ),
          label: host
        )
      end

      private def healthcheck_url(
        host : String,
        proxy : Config::ServerProxyConfig,
        container_name : String,
      ) : String
        ip_result = run_ssh!(
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
        run_ssh(host, ["systemctl", "--user", "stop", service_unit(color)])
        run_ssh(host, ["rm", "-f", container_path(color)])
        run_ssh(host, ["systemctl", "--user", "daemon-reload"])
      rescue ex : SSH::ConnectionError
        log(host, "Cleanup failed: #{ex.message || ex.class.name}")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end

      private def deploy_role(
        role : String,
        abort_rollout : RolloutAbort,
        &on_host_success : String -> Nil
      ) : RoleDeployResult
        hosts = hosts_for_role(role)
        limit = @config.boot.limit
        remaining_hosts = hosts.dup

        until remaining_hosts.empty? || abort_rollout.requested?
          batch = remaining_hosts.shift(limit)
          batch_result_channel = Channel(HostDeployResult).new(batch.size)
          batch_errors = [] of DeployFailed

          batch.each do |host|
            spawn do
              begin
                deploy_host(host, role)
                batch_result_channel.send(HostDeployResult.new(role: role, host: host, error: nil))
              rescue ex : DeployFailed
                batch_result_channel.send(HostDeployResult.new(role: role, host: host, error: ex))
              end
            end
          end

          batch.size.times do
            result = batch_result_channel.receive
            if error = result.error
              abort_rollout.request(error)
              batch_errors << error
            else
              log(result.host, "Deploy completed")
              on_host_success.call(result.host)
            end
          end

          if error = batch_errors.first?
            return RoleDeployResult.new(role: role, error: error)
          end

          sleep_between_batches if remaining_hosts.present? && !abort_rollout.requested?
        end

        RoleDeployResult.new(role: role, error: nil)
      end

      private def deploy_role(role : String, abort_rollout : RolloutAbort) : RoleDeployResult
        deploy_role(role, abort_rollout) do |_host|
        end
      end

      private def deploy_host(host : String, role : String) : Nil
        server = server_config(role)

        if role == "web" && server.proxy
          zero_downtime_deploy_to_host(host, role)
        else
          deploy_to_host(host, role)
        end
      end

      private def ordered_secondary_roles : Array(String)
        @config.servers.keys.reject { |role| role == "web" }
      end

      private def hosts_for_role(role : String) : Array(String)
        hosts = server_config(role).hosts
        raise DeployFailed.new("No hosts configured for role: #{role}") if hosts.empty?

        hosts
      end

      private def sleep_between_batches : Nil
        wait_seconds = @config.boot.wait
        return if wait_seconds.zero?

        @batch_sleeper.call(wait_seconds.seconds)
      end

      private def validate_rollout_settings! : Nil
        if @config.boot.limit < 1
          raise DeployFailed.new("boot.limit must be at least 1")
        end

        if @config.boot.wait < 0
          raise DeployFailed.new("boot.wait must be non-negative")
        end
      end

      private def transfer_image_to_host(host : String, image : String) : Nil
        transfer_mode = @config.transfer.try(&.mode)

        if transfer_mode.nil? || transfer_mode.registry?
          if registry = @config.registry
            login_to_registry(host, registry)
          end
          log(host, "Pulling image #{image}")
          run_ssh!(host, ["podman", "pull", image])
        elsif transfer_mode.stream?
          @stream_transfer.transfer(host, image)
        else
          @incremental_transfer.transfer(host, image)
        end
      rescue ex : Transfer::DependencyMissing | Transfer::TransferFailed
        raise DeployFailed.new(ex.message || "Image transfer to #{host} failed")
      end

      private def login_to_registry(host : String, registry : Config::RegistryConfig) : Nil
        server = registry.server || raise DeployFailed.new("registry.server is required")
        username = registry.username || raise DeployFailed.new("registry.username is required")
        password_var = registry.password.first? || raise DeployFailed.new("registry.password must specify an environment variable name")
        password = ENV[password_var]

        log(host, "Logging in to #{server}")
        run_ssh!(host, ["podman", "login", server, "--username", username, "--password-stdin"], input: password)
      end

      private def validate_registry_credentials! : Nil
        return unless registry = @config.registry

        transfer_mode = @config.transfer.try(&.mode)
        return if transfer_mode && !transfer_mode.registry?

        registry.password.each do |var_name|
          ENV[var_name]? || raise DeployFailed.new(
            "Environment variable #{var_name} (required by registry.password) is not set"
          )
        end
      end

      private def run_ssh(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run(
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

      private def run_ssh!(host : String, command : Array(String), input : String? = nil) : SSH::Result
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

      private def upload_ssh(host : String, remote_path : String, content : String) : Nil
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

      private def ssh_user : String?
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

      private def run_pre_deploy_hook : Nil
        return unless script = @config.hooks.try(&.pre_deploy)
        @output.puts "Running pre-deploy hook: #{script}"
        exit_code = @hook_runner.call(script, hook_env)
        raise DeployFailed.new("Pre-deploy hook failed (exit #{exit_code}): #{script}") unless exit_code == 0
      end

      private def run_post_deploy_hook : Nil
        return unless script = @config.hooks.try(&.post_deploy)
        @output.puts "Running post-deploy hook: #{script}"
        exit_code = @hook_runner.call(script, hook_env)
        @output.puts "Warning: post-deploy hook failed (exit #{exit_code}): #{script}" unless exit_code == 0
      end

      private def hook_env : Hash(String, String)
        hosts = @config.servers.values.flat_map(&.hosts).uniq!
        {
          "MERIDIAN_SERVICE" => @config.service,
          "MERIDIAN_HOSTS"   => hosts.join(","),
          "MERIDIAN_VERSION" => Meridian::VERSION,
        }
      end
    end
  end
end
