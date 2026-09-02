module Meridian
  module Deploy
    class Orchestrator
      include HealthPolling

      DEFAULT_COLOR            = Quadlet::Color::Green
      LEGACY_ACTIVE_COLOR_FILE = Runtime::Paths::LEGACY_ACTIVE_COLOR_FILE
      DEPLOY_LOCK_MESSAGE      = "meridian deploy"
      EMPTY_ACCESSORIES        = {} of String => Config::AccessoryConfig
      EMPTY_CONFLICTS          = [] of String

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
        @health_sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration },
        @hook_runner : Proc(String, Hash(String, String), Int32) = ->(script : String, env : Hash(String, String)) { Process.run(script, env: env, shell: true).exit_code },
        @file_reader : Proc(String, String) = ->(path : String) { File.read(path) },
        lock_manager : Lock::Manager? = nil,
        audit_logger : Audit::Logger? = nil,
        local_image_probe : LocalImageProbe? = nil,
        proxy_manager : Proxy::Manager? = nil,
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
        @proxy_manager = proxy_manager || Proxy::Manager.new(
          @config,
          ssh_executor: @ssh_executor,
          quadlet_generator: @quadlet_generator,
          output: @output,
          audit_logger: @audit_logger,
          drain_sleeper: @health_sleeper
        )
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
      ) : Nil
        server = server_config(role)
        return deploy_existing_units_to_host(host, role, server) unless server.managed?
        require_service_network!(host, "meridian deploy")
        require_accessory_preflight!(host)

        deployed_service_name = role_service_name(role)
        service_unit = role_service_unit(role)
        container_file = @quadlet_generator.role_container_file(role, server)
        image = server.image || @config.image

        run_remote_hooks(host, role, "before_transfer")
        transfer_image_to_host(host, image)
        run_remote_hooks(host, role, "after_transfer")

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
        ensure_service_state_dir(host)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, role_container_path(role), container_file)

        cleanup_legacy_color_units(host) unless proxied_role_on_host?(host)

        upload_file_syncs(host, role)
        run_remote_hooks(host, role, "after_upload")

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        wait_for_accessories(host)

        run_remote_hooks(host, role, "before_start")

        active_service = run_ssh(host, ["systemctl", "--user", "is-active", service_unit])
        if active_service.exit_code.zero?
          log(host, "Stopping existing service #{service_unit}")
          run_ssh!(host, ["systemctl", "--user", "stop", service_unit])
        end

        log(host, "Starting service #{deployed_service_name}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit])
        run_remote_hooks(host, role, "after_start")
        record_service_manifest(host)
        run_remote_hooks(host, role, "after_deploy")
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Deploy to #{host} failed")
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def zero_downtime_deploy_to_host(host : String, role : String) : Nil
        server = server_config(role)
        return deploy_existing_units_to_host(host, role, server) unless server.managed?
        require_service_network!(host, "meridian deploy")
        require_accessory_preflight!(host)

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

        log(host, "Uploading shared proxy network Quadlet")
        upload_proxy_network_quadlet(host)

        log(host, "Uploading service Quadlet")
        upload_ssh(host, container_path(new_color), @quadlet_generator.container_file(server, new_color))

        upload_file_syncs(host, role)

        if @config.assets
          upload_assets_to_host(host, release_id)
        end
        run_remote_hooks(host, role, "after_upload")

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        wait_for_accessories(host)

        run_remote_hooks(host, role, "before_start")

        if @config.assets
          run_asset_build_on_host(host)
        end

        log(host, "Starting service #{service_unit(new_color)}")
        run_ssh!(host, ["systemctl", "--user", "start", service_unit(new_color)])
        run_remote_hooks(host, role, "after_start")

        proxy_committed = false
        begin
          log(host, "Checking health for #{new_service}")
          poll_container_health(host, proxy, new_service)

          run_remote_hooks(host, role, "before_switch")

          log(host, "Switching proxy traffic to #{new_service}")
          @proxy_manager.switch(host, proxy, "#{new_service}:#{proxy.app_port}")
          proxy_committed = true
          run_remote_hooks(host, role, "after_switch")
        rescue ex : Proxy::SwitchUncertain
          raise DeployFailed.new(ex.message || "Caddy switch state is uncertain")
        rescue ex : Health::CheckFailed | SSH::CommandFailed | SSH::ConnectionError | Proxy::RouteFailed
          cleanup_failed_candidate(host, new_color) unless proxy_committed
          raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
        end

        if old_active
          log(host, "Draining #{service_name(old_color)}")
          @proxy_manager.drain(host, "#{service_name(old_color)}:#{proxy.app_port}")
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

        prune_images(host)
        run_remote_hooks(host, role, "after_deploy")
      rescue ex : SSH::CommandFailed | SSH::ConnectionError | Proxy::RouteFailed
        raise DeployFailed.new(ex.message || "Zero-downtime deploy to #{host} failed")
      end

      def deploy(targets : Array(CLI::TargetSelector::Target)? = nil) : Nil
        validate_recreate_targets!(targets)
        validate_local_images!(targets)
        validate_file_sources!(targets)
        validate_accessory_readiness!
        validate_registry_config!
        validate_rollout_settings!
        run_pre_deploy_hook
        @lock_manager.acquire(DEPLOY_LOCK_MESSAGE)
        begin
          run_deploy(targets)
        ensure
          release_deploy_lock
        end
      end

      private def validate_recreate_targets!(targets : Array(CLI::TargetSelector::Target)?) : Nil
        return unless @config.recreate? && targets

        raise DeployFailed.new(
          "strategy: recreate requires a full-service deploy; --role and --host cannot select a deployment subset"
        )
      end

      private def validate_local_images!(targets : Array(CLI::TargetSelector::Target)?) : Nil
        mode = @config.transfer.try(&.mode)
        return if mode.nil? || mode.registry?

        images = selected_roles(targets).map { |role| @config.servers[role]?.try(&.image) || @config.image }.uniq!
        missing = images.reject { |image| @local_image_probe.call(image) }
        return if missing.empty?

        label = missing.size == 1 ? "image" : "images"
        raise DeployFailed.new(
          "Local #{label} not found for #{mode.to_s.downcase} transfer: #{missing.join(", ")}. Build or pull #{missing.size == 1 ? "it" : "them"} locally before deploying."
        )
      end

      # Pre-lock readability check for every `files:` source the selected roles will
      # upload. Reading through `@file_reader` (the same seam `upload_file_syncs`
      # uses) catches missing, unreadable, and non-file sources locally instead of
      # mid-rollout with the deploy lock held.
      private def validate_file_sources!(targets : Array(CLI::TargetSelector::Target)?) : Nil
        return if @config.files.empty?

        roles = selected_roles(targets)
        @config.files.each do |file_sync|
          next unless roles.any? { |role| file_sync.applies_to?(role) }

          begin
            @file_reader.call(file_sync.source)
          rescue ex : IO::Error
            raise DeployFailed.new(
              "files: source #{file_sync.source} (destination #{file_sync.destination}) cannot be read: #{ex.message}"
            )
          end
        end
      end

      # Pre-lock resolution of every co-network accessory's readiness contract, so an
      # image Meridian cannot infer a probe for fails locally rather than inside a
      # host fiber during `wait_for_accessories`.
      private def validate_accessory_readiness! : Nil
        co_network_accessories.each do |name, accessory|
          accessory.effective_ready(name)
        rescue ex : Config::ValidationError
          raise DeployFailed.new(ex.message || "accessory '#{name}' readiness could not be resolved")
        end
      end

      private def selected_roles(targets : Array(CLI::TargetSelector::Target)?) : Array(String)
        targets ? targets.map(&.role).uniq! : @config.servers.keys.to_a
      end

      private def release_deploy_lock : Nil
        @lock_manager.release(announce: false)
      rescue ex : Lock::LockError
        @output.puts "Warning: failed to release deploy lock: #{ex.message}"
      end

      private def run_deploy(targets : Array(CLI::TargetSelector::Target)?) : Nil
        @allowed_hosts = build_allowed_hosts(targets)
        if @config.recreate?
          run_recreate_deploy
          @output.puts "Deploy completed"
          run_post_deploy_hook
          return
        end

        web_hosts = hosts_for_role?("web")
        secondary_roles = ordered_secondary_roles
        abort_rollout = RolloutAbort.new
        secondary_count = secondary_roles.size
        secondary_results = Channel(RoleDeployResult).new(secondary_count)
        secondary_started = false
        secondary_started_mutex = Mutex.new

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
                result =
                  begin
                    deploy_role(role, abort_rollout)
                  rescue ex : Exception
                    RoleDeployResult.new(role: role, error: deploy_failure(ex, "Deploy of role #{role}"))
                  end
                secondary_results.send(result)
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

      private def run_recreate_deploy : Nil
        host = hosts_for_role("web").first
        web = server_config("web")
        proxy = web.proxy || raise DeployFailed.new("strategy: recreate requires servers.web.proxy")
        secondary_roles = ordered_secondary_roles
        roles = ["web"] + secondary_roles
        stored_color = stored_active_color_entry(host)
        old_color = stored_color.try(&.color) || detect_current_color(host)
        old_active = service_active?(host, old_color)
        migrate_legacy_active_color(host, old_color) if stored_color.try(&.path) == LEGACY_ACTIVE_COLOR_FILE
        new_color = inactive_color(old_color)
        release_id = generate_release_id
        maintenance_started = false
        candidate_started = false
        candidate_healthy = false
        resumed = false

        begin
          @output.puts "Deploying #{@config.service} with recreate strategy on #{host}"
          require_service_network!(host, "meridian deploy")
          require_proxy_network!(host)
          require_accessory_preflight!(host)

          roles.each do |role|
            server = server_config(role)
            run_remote_hooks(host, role, "before_transfer")
            transfer_image_to_host(host, server.image || @config.image)
            run_remote_hooks(host, role, "after_transfer")
          end

          log(host, "Ensuring Quadlet directory exists")
          run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])
          ensure_service_state_dir(host)

          log(host, "Uploading shared proxy network Quadlet")
          upload_proxy_network_quadlet(host)
          log(host, "Uploading service Quadlet")
          upload_ssh(host, container_path(new_color), @quadlet_generator.container_file(web, new_color))
          secondary_roles.each do |role|
            log(host, "Uploading #{role} role Quadlet")
            upload_ssh(host, role_container_path(role), @quadlet_generator.role_container_file(role, server_config(role)))
          end

          log(host, "Reloading user systemd")
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
          wait_for_accessories(host)

          active_secondary_roles = secondary_roles.select do |role|
            run_ssh(host, ["systemctl", "--user", "is-active", role_service_unit(role)]).exit_code.zero?
          end

          if old_active || active_secondary_roles.present?
            log(host, "Putting #{@config.service} into maintenance")
            @proxy_manager.maintenance(host, proxy, "#{service_name(old_color)}:#{proxy.app_port}")
            maintenance_started = true
            @audit_logger.record(host, "maintenance", "begin old=#{old_color.slug} new=#{new_color.slug}")
            @proxy_manager.drain(host, "#{service_name(old_color)}:#{proxy.app_port}") if old_active

            active_secondary_roles.each do |role|
              stop_unit!(host, role_service_unit(role))
            end
            stop_unit!(host, service_unit(old_color)) if old_active
          end

          roles.each { |role| upload_file_syncs(host, role) }
          roles.each { |role| run_remote_hooks(host, role, "after_upload") }
          log(host, "Reloading user systemd after file syncs")
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

          run_remote_hooks(host, "web", "before_start")
          log(host, "Starting service #{service_unit(new_color)}")
          run_ssh!(host, ["systemctl", "--user", "start", service_unit(new_color)])
          candidate_started = true
          run_remote_hooks(host, "web", "after_start")

          log(host, "Checking health for #{service_name(new_color)}")
          poll_container_health(host, proxy, service_name(new_color))
          candidate_healthy = true

          secondary_roles.each do |role|
            unit = role_service_unit(role)
            run_remote_hooks(host, role, "before_start")
            log(host, "Starting service #{unit}")
            run_ssh!(host, ["systemctl", "--user", "start", unit])
            ensure_unit_active!(host, unit)
            run_remote_hooks(host, role, "after_start")
          end

          run_remote_hooks(host, "web", "before_switch")
          log(host, "Switching proxy target to #{service_name(new_color)}")
          @proxy_manager.switch(host, proxy, "#{service_name(new_color)}:#{proxy.app_port}")
          resumed = true
          run_remote_hooks(host, "web", "after_switch")

          log(host, "Recording active color #{new_color.slug}")
          record_active_color(host, new_color)
          record_release(host, "web", new_color, web.image || @config.image, release_id)
          record_service_manifest(host)

          log(host, "Removing inactive Quadlet #{container_path(old_color)}")
          run_ssh!(host, ["rm", "-f", container_path(old_color)])
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
          prune_images(host)

          if maintenance_started
            @audit_logger.record(host, "maintenance", "end active=#{new_color.slug}")
          end

          roles.each { |role| record_deploy_audit(host, role) }
          roles.each { |role| run_remote_hooks(host, role, "after_deploy") }
        rescue ex : Exception
          failure = deploy_failure(ex, "Recreate deploy on #{host}")
          stop_unhealthy_candidate(host, new_color) if candidate_started && !candidate_healthy

          if maintenance_started && !resumed
            @audit_logger.record(host, "maintenance", "failed: #{failure.message}")
            raise DeployFailed.new(recreate_maintenance_failure(host, old_color, new_color, secondary_roles, failure), failure)
          end

          raise failure
        end
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

      private def role_service_name(role : String) : String
        "#{@config.service}-#{role}"
      end

      private def role_service_unit(role : String) : String
        "#{role_service_name(role)}.service"
      end

      private def container_path(color : Quadlet::Color) : String
        File.join(Quadlet::DIRECTORY, "#{service_name(color)}.container")
      end

      private def role_container_path(role : String) : String
        File.join(Quadlet::DIRECTORY, "#{role_service_name(role)}.container")
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

      # Blocks until every accessory the app depends on answers its readiness
      # probe, so the app container does not start before aardvark-dns can
      # resolve its dependencies. Probes run from a pinned sidecar on the
      # accessory's own network (tcp/http) or via `podman exec` against the
      # accessory (cmd).
      private def wait_for_accessories(host : String) : Nil
        accessories = co_network_accessories
        return if accessories.empty?

        @output.puts "[#{host}] Waiting for accessories: #{accessories.keys.join(", ")}"
        accessories.each do |name, accessory|
          wait_for_accessory(host, name, accessory)
        end
      end

      # Accessories the app depends on - those whose network it automatically
      # joins - and therefore gated on before the app starts. Shared by the
      # readiness wait and its pre-lock validation.
      private def co_network_accessories : Hash(String, Config::AccessoryConfig)
        @config.dependent_accessories
      end

      private def wait_for_accessory(host : String, name : String, accessory : Config::AccessoryConfig) : Nil
        ready = accessory.effective_ready(name)
        budget = {ready.retries * ready.interval, 1}.max
        @output.puts "[#{host}] Waiting for #{name} on #{ready.summary}…"

        started = Time.instant
        network = accessory.network_name || @config.service
        result = run_ssh(host, accessory_wait_command(name, ready, budget, network))
        elapsed = (Time.instant - started).total_seconds.round(1)

        unless result.exit_code.zero?
          detail = result.stderr.presence || result.stdout.presence || "timed out after #{budget}s"
          raise DeployFailed.new(
            "Accessory '#{name}' not ready after #{budget}s: #{detail.strip}. Run `meridian accessory start #{name}` if it is not running."
          )
        end

        @output.puts "[#{host}] #{name} ready (#{elapsed}s)"
      end

      # Remote command that blocks until the accessory's readiness probe passes,
      # bounded by `timeout`. tcp/http run a single sidecar with the retry loop
      # inside the container (one `podman run`, not one per attempt); cmd loops a
      # host-side `podman exec` against the already-running accessory.
      private def accessory_wait_command(
        name : String,
        ready : Config::AccessoryReadinessConfig,
        budget : Int32,
        network : String,
      ) : Array(String)
        interval = ready.interval
        image = Config::HealthcheckConfig::DEFAULT_PROBE_IMAGE
        guard = ["timeout", "-k", "5", budget.to_s]

        if ports = ready.tcp
          inner = ports.map { |port| "nc -z #{name} #{port}" }.join(" && ")
          guard + ["podman", "run", "--rm", "--network=#{network}", image, "sh", "-c", "until #{inner}; do sleep #{interval}; done"]
        elsif endpoint = ready.http
          inner = "wget -q -O- http://#{name}:#{endpoint.port}#{endpoint.path} >/dev/null 2>&1"
          guard + ["podman", "run", "--rm", "--network=#{network}", image, "sh", "-c", "until #{inner}; do sleep #{interval}; done"]
        elsif command = ready.cmd
          inner = "podman exec #{name} #{command.map { |part| Process.quote_posix(part) }.join(" ")} >/dev/null 2>&1"
          guard + ["sh", "-c", "until #{inner}; do sleep #{interval}; done"]
        else
          raise DeployFailed.new("accessory '#{name}' has no readiness probe")
        end
      end

      private def stop_unit!(host : String, unit : String) : Nil
        log(host, "Stopping service #{unit}")
        run_ssh!(host, ["systemctl", "--user", "stop", unit])
        result = run_ssh(host, ["systemctl", "--user", "is-active", unit])
        return unless result.exit_code.zero?

        raise DeployFailed.new("Service #{unit} is still active after systemctl stop")
      end

      private def ensure_unit_active!(host : String, unit : String) : Nil
        result = run_ssh(host, ["systemctl", "--user", "is-active", unit])
        return if result.exit_code.zero?

        detail = result.stderr.presence || result.stdout.presence || "inactive"
        raise DeployFailed.new("Service #{unit} did not become active: #{detail.strip}")
      end

      private def stop_unhealthy_candidate(host : String, color : Quadlet::Color) : Nil
        unit = service_unit(color)
        log(host, "Stopping unhealthy recreate candidate #{unit}")
        result = run_ssh(host, ["systemctl", "--user", "stop", unit])
        log(host, "Warning: failed to stop unhealthy candidate #{unit}: #{result.stderr.strip}") unless result.exit_code.zero?
      rescue ex : SSH::ConnectionError
        log(host, "Warning: failed to stop unhealthy candidate #{unit}: #{ex.message || ex.class.name}")
      end

      private def recreate_maintenance_failure(
        host : String,
        old_color : Quadlet::Color,
        new_color : Quadlet::Color,
        secondary_roles : Array(String),
        failure : DeployFailed,
      ) : String
        units = [service_unit(old_color), service_unit(new_color)] + secondary_roles.map { |role| role_service_unit(role) }
        unit_args = units.join(" ")
        "Recreate deploy failed after maintenance began: #{failure.message}. " \
        "#{@config.service} remains in maintenance and Meridian did not restart the old release, resume the proxy, or roll back images because persistent data may have been migrated. " \
        "Inspect `systemctl --user status #{unit_args}` and `journalctl --user #{units.map { |unit| "-u #{unit}" }.join(" ")} -n 100 --no-pager` on #{host}. " \
        "After repairing and verifying the service, rerun `meridian deploy` to replace the persisted Caddy maintenance route."
      end

      private def cleanup_failed_candidate(host : String, color : Quadlet::Color) : Nil
        log(host, "Cleaning up failed candidate #{service_name(color)}")
        run_ssh(host, ["systemctl", "--user", "stop", service_unit(color)])
        run_ssh(host, ["rm", "-f", container_path(color)])
        run_ssh(host, ["systemctl", "--user", "daemon-reload"])
      rescue ex : SSH::ConnectionError
        log(host, "Cleanup failed: #{ex.message || ex.class.name}")
      end

      private def proxied_role_on_host?(host : String) : Bool
        @config.servers.any? do |_role, server|
          server.managed? && !server.proxy.nil? && server.hosts.includes?(host)
        end
      end

      private def cleanup_legacy_color_units(host : String) : Nil
        blue_path = container_path(Quadlet::Color::Blue)
        green_path = container_path(Quadlet::Color::Green)
        blue_unit = service_unit(Quadlet::Color::Blue)
        green_unit = service_unit(Quadlet::Color::Green)
        command = <<-SH
          for entry in #{Process.quote_posix("#{blue_path}:#{blue_unit}")} #{Process.quote_posix("#{green_path}:#{green_unit}")}; do
            file=${entry%%:*}
            unit=${entry#*:}
            if test -f "$file"; then
              systemctl --user stop "$unit"
              rm -f "$file"
            fi
          done
          SH

        log(host, "Cleaning up legacy color Quadlets")
        run_ssh!(host, ["sh", "-lc", command])
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
              result =
                begin
                  deploy_host(host, role)
                  HostDeployResult.new(role: role, host: host, error: nil)
                rescue ex : Exception
                  HostDeployResult.new(
                    role: role,
                    host: host,
                    error: deploy_failure(ex, "Deploy to #{host} (role: #{role})")
                  )
                end
              batch_result_channel.send(result)
            end
          end

          batch.size.times do
            result = batch_result_channel.receive
            if error = result.error
              # Only the first error is propagated, so every other failing host in
              # the batch would otherwise vanish from the operator's output.
              log(result.host, "Deploy failed: #{error.message}")
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

      # Every spawned fiber must report exactly one result, so anything that is not
      # already a DeployFailed is wrapped with the context of the operation that
      # raised it. The rollout then fails loudly instead of leaving the main fiber
      # waiting forever on a result that never arrives while it holds the deploy lock.
      private def deploy_failure(ex : Exception, context : String) : DeployFailed
        return ex if ex.is_a?(DeployFailed)

        DeployFailed.new("#{context} failed: #{ex.class.name}: #{ex.message}", ex)
      end

      # Keyed on `proxy:` alone, like every other proxy-aware branch (Quadlet unit
      # naming, status, logs, exec, manifest). Config validation guarantees only the
      # web role can carry `proxy:`, so a role name check here would be redundant -
      # and a second, weaker copy of that rule is what previously let a proxied role
      # deploy through the restart-in-place path while the rest of the CLI looked for
      # blue/green units.
      private def deploy_host(host : String, role : String) : Nil
        server = server_config(role)

        if server.proxy
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

      # Pre-lock completeness check for the registry path: decided locally before any
      # remote mutation, lock acquisition, or pre-deploy hook. `login_to_registry` keeps
      # its own defensive raises as a per-host backstop.
      private def validate_registry_config! : Nil
        return unless registry = @config.registry

        transfer_mode = @config.transfer.try(&.mode)
        return if transfer_mode && !transfer_mode.registry?

        raise DeployFailed.new("registry.server is required") unless registry.server.presence
        raise DeployFailed.new("registry.username is required") unless registry.username.presence
        raise DeployFailed.new("registry.password must specify an environment variable name") if registry.password.first?.nil?

        registry.password.each do |var_name|
          value = ENV[var_name]?
          raise DeployFailed.new("Environment variable #{var_name} (required by registry.password) is not set") if value.nil?
          raise DeployFailed.new("Environment variable #{var_name} (required by registry.password) is set but empty") if value.empty?
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
          next unless file_sync.applies_to?(role)

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

      private def upload_proxy_network_quadlet(host : String) : Nil
        upload_ssh(host, proxy_network_path, @quadlet_generator.proxy_network_file)
      end

      private def require_service_network!(host : String, command : String) : Nil
        result = run_ssh(host, Runtime::ServiceNetwork.exists_command(@config.service))
        return if result.exit_code.zero?

        raise DeployFailed.new(Runtime::ServiceNetwork.missing_message(@config.service, host, command))
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect service network on #{host}")
      end

      # Every accessory network the app joins must already exist on the host:
      # the app container declares `Network=` for it, so a missing network is a
      # start failure rather than a degraded deploy. Deploy never creates it -
      # `meridian accessory start` does.
      private def require_accessory_networks!(host : String) : Nil
        @config.dependent_accessories.each do |name, accessory|
          network = accessory.network_name
          next if network.nil? || @config.generated_network?(network)

          result = run_ssh(host, Runtime::ServiceNetwork.network_exists_command(network))
          next if result.exit_code.zero?

          raise DeployFailed.new(
            Runtime::ServiceNetwork.missing_accessory_network_message(network, host, name)
          )
        end
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect accessory networks on #{host}")
      end

      # Refuses to deploy against a host where another service already declares
      # one of these accessories with a different definition. Narrower than the
      # full `meridian check` collision report on purpose: deploy verifies only
      # what it needs to start the app safely.
      private def reject_accessory_conflicts!(host : String) : Nil
        result = run_ssh(host, Runtime::ServiceManifest.list_command)
        return unless result.exit_code.zero?

        current = Runtime::ServiceManifest.from_config(@config)
        conflicts = Runtime::ServiceManifest.parse_all(result.stdout).flat_map do |manifest|
          manifest.service == @config.service ? EMPTY_CONFLICTS : current.accessory_collisions_with(manifest)
        end
        return if conflicts.empty?

        raise DeployFailed.new("Accessory conflict on #{host}: #{conflicts.join("; ")}")
      rescue ex : JSON::ParseException
        raise DeployFailed.new("Invalid Meridian service manifest on #{host}: #{ex.message}")
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect service manifests on #{host}")
      end

      # Deploy verifies only the accessories it actually depends on: those whose
      # network the app joins. An accessory with no network is not part of the
      # rollout, so `meridian check` is where it gets reported.
      private def require_accessory_preflight!(host : String) : Nil
        return if @config.dependent_accessories.empty?

        reject_accessory_conflicts!(host)
        require_accessory_networks!(host)
      end

      private def require_proxy_network!(host : String) : Nil
        network = Runtime::Paths::SHARED_PROXY_NETWORK
        result = run_ssh(host, ["podman", "network", "exists", network])
        return if result.exit_code.zero?

        raise DeployFailed.new("Proxy network #{network} is not available on #{host}. Run `meridian setup` before `meridian deploy`.")
      rescue ex : SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Failed to inspect proxy network on #{host}")
      end

      private def prune_images(host : String) : Nil
        log(host, "Pruning unused images")
        result = run_ssh(host, ["podman", "image", "prune", "-f"])
        log(host, "Image prune failed with exit code #{result.exit_code}") unless result.exit_code.zero?
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
        log(host, "Ensuring assets release directory exists")
        run_ssh!(host, ["mkdir", "-p", assets_directory])

        log(host, "Uploading assets builder Quadlet")
        upload_ssh(host, assets_builder_quadlet_path, @quadlet_generator.assets_builder_file(release_id))
      end

      private def run_asset_build_on_host(host : String) : Nil
        assets = @config.assets || raise DeployFailed.new("assets configuration missing")

        log(host, "Running asset builder")
        run_ssh!(host, ["systemctl", "--user", "restart", "#{@config.service}-assets-builder.service"])

        log(host, "Publishing assets through Caddy")
        @proxy_manager.register_assets(host)

        # The `:U` builder mount leaves release directories owned by a mapped
        # subuid, so only the user namespace can remove them.
        log(host, "Pruning old asset releases (keeping #{assets.retain_releases})")
        find_cmd = "find #{Process.quote_posix(assets_directory)} -maxdepth 1 -mindepth 1 -type d | " \
                   "sort | head -n -#{assets.retain_releases} | xargs -r rm -rf"
        prune_result = run_ssh(host, ["bash", "-c", "podman unshare sh -c #{Process.quote_posix(find_cmd)}"])
        unless prune_result.exit_code.zero?
          log(host, "Asset release pruning failed with exit code #{prune_result.exit_code}")
        end
      end

      private def assets_directory : String
        Runtime::Paths.assets_directory(@config.service)
      end

      private def assets_builder_quadlet_path : String
        File.join(Quadlet::DIRECTORY, "#{@config.service}-assets-builder.container")
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
