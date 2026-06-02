module Meridian
  module Deploy
    class Orchestrator
      DEFAULT_COLOR            = Quadlet::Color::Green
      LEGACY_ACTIVE_COLOR_FILE = Runtime::Paths::LEGACY_ACTIVE_COLOR_FILE
      DEPLOY_LOCK_MESSAGE      = "meridian deploy"

      private record HostDeployResult,
        role : String,
        host : String,
        error : DeployFailed?

      private record RoleDeployResult,
        role : String,
        error : DeployFailed?

      private record StoredActiveColor,
        color : Quadlet::Color,
        path : String

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

      @allowed_hosts : Hash(String, Array(String))? = nil

      alias LocalImageProbe = Proc(String, Bool)

      DEFAULT_LOCAL_IMAGE_PROBE = ->(image : String) do
        Process.run("podman", ["image", "exists", image]).success?
        rescue
          false
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
        @file_reader : Proc(String, String) = ->(path : String) { File.read(path) },
        lock_manager : Lock::Manager? = nil,
        audit_logger : Audit::Logger? = nil,
        local_image_probe : LocalImageProbe? = nil,
      )
        @local_image_probe = local_image_probe || DEFAULT_LOCAL_IMAGE_PROBE
        @audit_logger = audit_logger || Audit::Logger.new(@config, @ssh_executor)
        @lock_manager = lock_manager || Lock::Manager.new(
          @config,
          @ssh_executor,
          output: @output,
          audit_logger: @audit_logger
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
        return deploy_existing_units_to_host(host, role, server) unless server.managed?

        deployed_service_name = service_name(color)
        service_unit = service_unit(color)
        container_file = @quadlet_generator.container_file(server, color)
        image = server.image || @config.image
        release_id = generate_release_id

        run_remote_hooks(host, role, "before_transfer")
        transfer_image_to_host(host, image)
        run_remote_hooks(host, role, "after_transfer")

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
        ensure_service_state_dir(host)

        log(host, "Uploading network Quadlet")
        upload_network_quadlets(host, include_proxy_network: !server.proxy.nil?)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, container_path(color), container_file)

        upload_file_syncs(host, role)
        run_remote_hooks(host, role, "after_upload")

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        run_remote_hooks(host, role, "before_start")

        active_service = run_ssh(host, ["systemctl", "--user", "is-active", service_unit])
        if active_service.exit_code.zero?
          log(host, "Stopping existing service #{service_unit}")
          run_ssh!(host, ["systemctl", "--user", "stop", service_unit])
        end

        log(host, "Starting service #{deployed_service_name}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit])
        run_remote_hooks(host, role, "after_start")
        record_active_color(host, color)
        record_release(host, role, color, image, release_id)
        record_service_manifest(host)
        run_remote_hooks(host, role, "after_deploy")
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Deploy to #{host} failed")
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def zero_downtime_deploy_to_host(host : String, role : String) : Nil
        server = server_config(role)
        return deploy_existing_units_to_host(host, role, server) unless server.managed?

        proxy = server.proxy || raise DeployFailed.new("Missing proxy configuration for role: #{role}")
        stored_color = stored_active_color_entry(host)
        old_color = stored_color.try(&.color) || detect_current_color(host)
        old_active = service_active?(host, old_color)
        migrate_legacy_active_color(host, old_color) if stored_color.try(&.path) == LEGACY_ACTIVE_COLOR_FILE
        new_color = inactive_color(old_color)
        new_service = service_name(new_color)
        image = server.image || @config.image
        release_id = generate_release_id

        run_remote_hooks(host, role, "before_transfer")
        transfer_image_to_host(host, image)
        run_remote_hooks(host, role, "after_transfer")

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
        ensure_service_state_dir(host)

        log(host, "Uploading network Quadlet")
        upload_network_quadlets(host, include_proxy_network: true)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, container_path(new_color), @quadlet_generator.container_file(server, new_color))

        upload_file_syncs(host, role)

        if @config.assets
          upload_assets_to_host(host, release_id)
        end
        run_remote_hooks(host, role, "after_upload")

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        run_remote_hooks(host, role, "before_start")

        if @config.assets
          run_asset_build_on_host(host)
        end

        log(host, "Starting service #{service_unit(new_color)}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit(new_color)])
        run_remote_hooks(host, role, "after_start")

        begin
          log(host, "Checking health for #{new_service}")
          poll_container_health(host, proxy, new_service)

          run_remote_hooks(host, role, "before_switch")

          log(host, "Switching proxy traffic to #{new_service}")
          run_ssh!(host, proxy_deploy_command(proxy, new_color))
          run_remote_hooks(host, role, "after_switch")
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
        record_active_color(host, new_color)
        record_release(host, role, new_color, image, release_id)
        record_service_manifest(host)

        log(host, "Pruning unused images")
        prune_result = run_ssh(host, ["podman", "image", "prune", "-f"])
        unless prune_result.exit_code.zero?
          log(host, "Image prune failed with exit code #{prune_result.exit_code}")
        end
        run_remote_hooks(host, role, "after_deploy")
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
      end

      def deploy(targets : Array(CLI::TargetSelector::Target)? = nil) : Nil
        validate_local_images!(targets)
        @lock_manager.acquire(DEPLOY_LOCK_MESSAGE)
        begin
          run_deploy(targets)
        ensure
          release_deploy_lock
        end
      end

      private def validate_local_images!(targets : Array(CLI::TargetSelector::Target)?) : Nil
        mode = @config.transfer.try(&.mode)
        return if mode.nil? || mode.registry?

        roles = targets ? targets.map(&.role).uniq! : @config.servers.keys.to_a
        images = roles.map { |role| @config.servers[role]?.try(&.image) || @config.image }.uniq!
        missing = images.reject { |image| @local_image_probe.call(image) }
        return if missing.empty?

        label = missing.size == 1 ? "image" : "images"
        raise DeployFailed.new(
          "Local #{label} not found for #{mode.to_s.downcase} transfer: #{missing.join(", ")}. Build or pull #{missing.size == 1 ? "it" : "them"} locally before deploying."
        )
      end

      private def release_deploy_lock : Nil
        @lock_manager.release(announce: false)
      rescue ex : Lock::LockError
        @output.puts "Warning: failed to release deploy lock: #{ex.message}"
      end

      private def run_deploy(targets : Array(CLI::TargetSelector::Target)?) : Nil
        @allowed_hosts = build_allowed_hosts(targets)
        validate_rollout_settings!
        validate_registry_credentials!
        run_pre_deploy_hook
        web_hosts = hosts_for_role?("web")
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

        web_result =
          if web_hosts.empty?
            @output.puts "Skipping web role (no targets selected)" if @allowed_hosts
            start_secondary_roles.call
            RoleDeployResult.new(role: "web", error: nil)
          else
            @output.puts "Deploying #{@config.service} to #{web_hosts.size} web host#{web_hosts.size == 1 ? "" : "s"}"
            deploy_role("web", abort_rollout) do |_host|
              start_secondary_roles.call
            end
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
      ensure
        @allowed_hosts = nil
      end

      private def build_allowed_hosts(targets : Array(CLI::TargetSelector::Target)?) : Hash(String, Array(String))?
        return if targets.nil?

        targets.each_with_object(Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }) do |target, acc|
          acc[target.role] << target.host unless acc[target.role].includes?(target.host)
        end
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

      private def proxy_network_path : String
        File.join(Quadlet::DIRECTORY, Runtime::Paths::SHARED_PROXY_NETWORK_FILE)
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
        stored_color = stored_active_color_entry(host)
        return stored_color.color if stored_color

        detect_current_color(host)
      end

      private def detect_current_color(host : String) : Quadlet::Color
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
        stored_active_color_entry(host).try(&.color)
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to read active color for #{host}")
      end

      private def stored_active_color_entry(host : String) : StoredActiveColor?
        if color = stored_color_at(host, active_color_file)
          return StoredActiveColor.new(color: color, path: active_color_file)
        end

        if color = stored_color_at(host, LEGACY_ACTIVE_COLOR_FILE)
          return StoredActiveColor.new(color: color, path: LEGACY_ACTIVE_COLOR_FILE)
        end
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to read active color for #{host}")
      end

      private def stored_color_at(host : String, path : String) : Quadlet::Color?
        result = run_ssh(host, ["cat", path])
        return unless result.exit_code.zero?

        color_name = result.stdout.strip
        return if color_name.empty?

        Quadlet::Color.parse?(color_name) || raise DeployFailed.new("Invalid active color stored on #{host}: #{color_name}")
      end

      private def service_active?(host : String, color : Quadlet::Color) : Bool
        run_ssh(host, ["systemctl", "--user", "is-active", service_unit(color)]).exit_code.zero?
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect service state for #{host}")
      end

      private def poll_container_health(
        host : String,
        proxy : Config::ServerProxyConfig,
        container_name : String,
      ) : Nil
        proxy_network = Runtime::Paths::SHARED_PROXY_NETWORK
        url = "http://#{container_name}:#{proxy.app_port}#{proxy.healthcheck.path}"
        timeout = proxy.healthcheck.timeout
        retries = proxy.healthcheck.retries
        interval = proxy.healthcheck.interval
        probe_image = proxy.healthcheck.probe_image
        host_header = proxy.host || container_name

        retries.times do |attempt|
          attempt_number = attempt + 1
          @output.puts "[#{host}] Health check attempt #{attempt_number}/#{retries}: #{container_name} -> #{url} (Host: #{host_header})"

          result = run_ssh(
            host,
            [
              "podman", "run", "--rm", "--network=#{proxy_network}",
              probe_image,
              "wget", "-q", "-O-",
              "--timeout=#{timeout}",
              "--header=Host: #{host_header}",
              url,
            ]
          )

          if result.exit_code.zero?
            @output.puts "[#{host}] Health check passed: #{container_name} -> #{url}"
            return
          end

          sleep interval.seconds if attempt < retries - 1
        end

        raise Health::CheckFailed.new("Health check failed for #{container_name} -> #{url} after #{retries} attempts")
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
              record_deploy_audit(result.host, role)
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

      private def record_deploy_audit(host : String, role : String) : Nil
        image = server_config(role).image || @config.image
        @audit_logger.record(host, "deploy", "role=#{role} image=#{image}")
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
        @config.servers.keys.reject { |role| role == "web" || hosts_for_role?(role).empty? }
      end

      private def hosts_for_role(role : String) : Array(String)
        hosts = hosts_for_role?(role)
        raise DeployFailed.new("No hosts configured for role: #{role}") if hosts.empty?

        hosts
      end

      private def hosts_for_role?(role : String) : Array(String)
        configured = server_config(role).hosts
        if allowed = @allowed_hosts
          allowed_for_role = allowed[role]? || [] of String
          configured.select { |host| allowed_for_role.includes?(host) }
        else
          configured
        end
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

      private def deploy_existing_units_to_host(
        host : String,
        role : String,
        server : Config::ServerConfig,
      ) : Nil
        run_remote_hooks(host, role, "before_transfer")
        transfer_image_to_host(host, server.image || @config.image)
        run_remote_hooks(host, role, "after_transfer")

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
        ensure_service_state_dir(host)

        upload_file_syncs(host, role)
        run_remote_hooks(host, role, "after_upload")

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        run_remote_hooks(host, role, "before_start")

        server.units.each do |unit|
          log(host, "Restarting existing unit #{unit}")
          run_ssh!(host, ["systemctl", "--user", "restart", unit])
        end

        run_remote_hooks(host, role, "after_start")
        record_service_manifest(host)
        run_remote_hooks(host, role, "after_deploy")
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Deploy to #{host} failed")
      end

      private def run_remote_hooks(host : String, role : String, phase : String) : Nil
        remote_hooks_for(phase).each do |hook|
          next if (roles = hook.roles) && !roles.includes?(role)

          log(host, "Running remote hook #{phase}: #{hook.command}")
          run_ssh!(host, ["sh", "-lc", hook.command])
        end
      end

      private def remote_hooks_for(phase : String) : Array(Config::RemoteHookConfig)
        hooks = @config.hooks.try(&.remote)
        return [] of Config::RemoteHookConfig unless hooks

        case phase
        when "before_transfer" then hooks.before_transfer
        when "after_transfer"  then hooks.after_transfer
        when "after_upload"    then hooks.after_upload
        when "before_start"    then hooks.before_start
        when "after_start"     then hooks.after_start
        when "before_switch"   then hooks.before_switch
        when "after_switch"    then hooks.after_switch
        when "after_deploy"    then hooks.after_deploy
        else
          [] of Config::RemoteHookConfig
        end
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

      private def upload_file_syncs(host : String, role : String) : Nil
        @config.files.each do |file_sync|
          next if (roles = file_sync.roles) && !roles.includes?(role)

          content = @file_reader.call(file_sync.source)
          content = @quadlet_generator.render_file_sync_template(content) if file_sync.template?

          log(host, "Uploading #{file_sync.source} → #{file_sync.destination}")
          upload_ssh(host, file_sync.destination, content)
        end
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

      private def upload_network_quadlets(host : String, *, include_proxy_network : Bool) : Nil
        upload_ssh(host, network_path, @quadlet_generator.network_file)
        upload_ssh(host, proxy_network_path, @quadlet_generator.proxy_network_file) if include_proxy_network
      end

      private def ensure_service_state_dir(host : String) : Nil
        run_ssh!(host, ["mkdir", "-p", Runtime::Paths.service_directory(@config.service)])
      end

      private def active_color_file : String
        Runtime::Paths.active_color_file(@config.service)
      end

      private def manifest_file : String
        Runtime::Paths.manifest_file(@config.service)
      end

      private def release_state_file : String
        Runtime::Paths.release_state_file(@config.service)
      end

      private def generate_release_id : String
        Time.utc.to_s("%Y%m%dT%H%M%SZ")
      end

      private def record_active_color(host : String, color : Quadlet::Color) : Nil
        content = "#{color.slug}\n"
        upload_ssh(host, active_color_file, content)
        upload_ssh(host, LEGACY_ACTIVE_COLOR_FILE, content)
      end

      private def migrate_legacy_active_color(host : String, color : Quadlet::Color) : Nil
        ensure_service_state_dir(host)
        upload_ssh(host, active_color_file, "#{color.slug}\n")
      end

      private def record_service_manifest(host : String) : Nil
        manifest = Runtime::ServiceManifest.from_config(@config)
        upload_ssh(host, manifest_file, "#{manifest.to_json}\n")
      end

      private def record_release(
        host : String,
        role : String,
        color : Quadlet::Color,
        image : String,
        release_id : String,
      ) : Nil
        record = Runtime::ReleaseRecord.new(
          service: @config.service,
          role: role,
          host: host,
          color: color.slug,
          image: image,
          release_id: release_id,
          deployed_at: Time.utc.to_rfc3339
        )
        state = Runtime::ReleaseState.promote(read_release_state(host), record)
        log(host, "Recording release #{release_id}")
        upload_ssh(host, release_state_file, "#{state.to_json}\n")
      end

      private def read_release_state(host : String) : Runtime::ReleaseState?
        result = run_ssh(host, ["cat", release_state_file])
        return unless result.exit_code.zero?

        text = result.stdout.strip
        return if text.empty?

        Runtime::ReleaseState.from_json(text)
      rescue JSON::ParseException
        log(host, "Ignoring unparseable release-state.json on #{host}")
        nil
      end

      private def ssh_user : String?
        @config.ssh.user
      end

      private def ssh_port : Int32?
        port = @config.ssh.port
        port == 22 ? nil : port
      end

      private def ssh_identity_file : String?
        @config.ssh.identity_file
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

      private def upload_assets_to_host(host : String, release_id : String) : Nil
        log(host, "Ensuring assets Caddy config directory exists")
        run_ssh!(host, ["mkdir", "-p", assets_caddy_dir])

        log(host, "Uploading assets Caddy config")
        upload_ssh(host, assets_caddy_config_path, @quadlet_generator.assets_caddy_config)

        log(host, "Uploading assets volume Quadlet")
        upload_ssh(host, assets_volume_quadlet_path, @quadlet_generator.assets_volume_file)

        log(host, "Uploading assets builder Quadlet")
        upload_ssh(host, assets_builder_quadlet_path, @quadlet_generator.assets_builder_file(release_id))

        log(host, "Uploading assets server Quadlet")
        upload_ssh(host, assets_server_quadlet_path, @quadlet_generator.assets_server_file)
      end

      private def run_asset_build_on_host(host : String) : Nil
        assets = @config.assets || raise DeployFailed.new("assets configuration missing")

        log(host, "Running asset builder")
        run_ssh!(host, ["systemctl", "--user", "restart", "#{@config.service}-assets-builder.service"])

        log(host, "Starting asset server")
        run_ssh!(host, ["systemctl", "--user", "start", "#{@config.service}-assets-server.service"])

        log(host, "Registering asset server with proxy")
        register_cmd = [
          "podman", "exec", "kamal-proxy", "kamal-proxy", "deploy",
          "#{@config.service}-assets",
          "--target", "#{@config.service}-assets-server:80",
          "--host", assets.host,
        ]
        register_cmd << "--tls" if @config.servers["web"]?.try(&.proxy).try(&.ssl?)
        run_ssh!(host, register_cmd)

        log(host, "Pruning old asset releases (keeping #{assets.retain_releases})")
        prune_cmd = "v=$(podman volume inspect #{@config.service}-assets --format '{{.Mountpoint}}') && " \
                    "find \"$v\" -maxdepth 1 -mindepth 1 -type d | sort | head -n -#{assets.retain_releases} | xargs -r rm -rf"
        prune_result = run_ssh(host, ["bash", "-c", prune_cmd])
        unless prune_result.exit_code.zero?
          log(host, "Asset release pruning failed with exit code #{prune_result.exit_code}")
        end
      end

      private def assets_caddy_dir : String
        File.join(".config", "containers", "#{@config.service}-assets-caddy")
      end

      private def assets_caddy_config_path : String
        File.join(assets_caddy_dir, "Caddyfile")
      end

      private def assets_volume_quadlet_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}-assets.volume")
      end

      private def assets_builder_quadlet_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}-assets-builder.container")
      end

      private def assets_server_quadlet_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}-assets-server.container")
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
