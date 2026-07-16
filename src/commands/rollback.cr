module Meridian
  module Commands
    class Rollback < Base
      include Deploy::HealthPolling

      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        output : IO = STDOUT,
        error : IO = STDERR,
        audit_logger : ::Meridian::Audit::Logger? = nil,
        quadlet_generator : Quadlet::Generator? = nil,
        @health_sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration },
      )
        super(config, ssh_executor, output, error, audit_logger)
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(config)
      end

      def run : Nil
        proxy = web_proxy

        hosts_for_role("web").sort.each do |host|
          state = read_release_state(host)
          if state
            rollback_with_state(host, proxy, state)
          else
            rollback_with_legacy_color(host, proxy)
          end
        end
      rescue ex : Config::UnknownRole | ArgumentError | SSH::CommandFailed | SSH::ConnectionError
        raise Deploy::RollbackFailed.new(ex.message || "Rollback failed")
      end

      private def rollback_with_state(
        host : String,
        proxy : Config::ServerProxyConfig,
        state : Runtime::ReleaseState,
      ) : Nil
        previous = state.previous || raise Deploy::RollbackFailed.new(
          "No rollback-safe release retained on #{host}"
        )

        rollback_color = Quadlet::Color.parse?(previous.color) ||
                         raise Deploy::RollbackFailed.new(
                           "Invalid stored release color on #{host}: #{previous.color}"
                         )
        old_color = inactive_color(rollback_color)

        unless image_exists?(host, previous.image)
          raise Deploy::RollbackFailed.new(
            "Rollback image #{previous.image} (release #{previous.release_id}) is no longer present on #{host}; dependable rollback requires per-release image tags"
          )
        end

        activate_reconstructed_release(host, proxy, previous, rollback_color)

        log(host, "Retiring #{service_name(old_color)}")
        run_ssh!(host, ["systemctl", "--user", "stop", service_unit(old_color)])
        run_ssh!(host, ["rm", "-f", container_path(old_color)])
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Recording active color #{rollback_color.slug}")
        record_active_color(host, rollback_color)

        log(host, "Recording rollback release #{previous.release_id}")
        write_release_state(host, state.swap)

        audit_logger.record(host, "rollback", "to release #{previous.release_id} (#{rollback_color.slug})")
      end

      # Rebuilds the previous release from its recorded image and colour, then
      # switches traffic to it. The old container no longer exists after a
      # successful deploy (Quadlet removes it on stop), so the unit is
      # reconstructed the same way a deploy brings up a new colour. On any
      # failure the candidate is torn down and the active release keeps serving.
      private def activate_reconstructed_release(
        host : String,
        proxy : Config::ServerProxyConfig,
        previous : Runtime::ReleaseRecord,
        rollback_color : Quadlet::Color,
      ) : Nil
        log(host, "Reconstructing release #{previous.release_id} (#{previous.image}) as #{service_name(rollback_color)}")
        upload_ssh(
          host,
          container_path(rollback_color),
          @quadlet_generator.container_file(server_config("web"), rollback_color, image: previous.image)
        )
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        run_ssh!(host, ["systemctl", "--user", "start", service_unit(rollback_color)])
        poll_container_health(host, proxy, service_name(rollback_color))
        switch_proxy(host, proxy, rollback_color)
      rescue ex : Health::CheckFailed | Deploy::RollbackFailed | SSH::CommandFailed | SSH::ConnectionError
        cleanup_failed_candidate(host, rollback_color)
        raise ex if ex.is_a?(Deploy::RollbackFailed)
        raise Deploy::RollbackFailed.new(ex.message || "Rollback failed")
      end

      private def cleanup_failed_candidate(host : String, color : Quadlet::Color) : Nil
        log(host, "Cleaning up failed rollback candidate #{service_name(color)}")
        run_ssh(host, ["systemctl", "--user", "stop", service_unit(color)])
        run_ssh(host, ["rm", "-f", container_path(color)])
        run_ssh(host, ["systemctl", "--user", "daemon-reload"])
      rescue ex : SSH::ConnectionError
        log(host, "Cleanup failed: #{ex.message || ex.class.name}")
      end

      private def rollback_with_legacy_color(host : String, proxy : Config::ServerProxyConfig) : Nil
        log(host, "No release-state.json found, using legacy active-color rollback")
        current_color = stored_active_color(host) || raise Deploy::RollbackFailed.new(
          "No active color recorded on #{host}"
        )
        rollback_color = inactive_color(current_color)
        rollback_target = service_name(rollback_color)

        unless container_exists?(host, rollback_target)
          raise Deploy::RollbackFailed.new("Rollback target #{rollback_target} is not present on #{host}")
        end

        ensure_container_running(host, rollback_target)
        switch_proxy(host, proxy, rollback_color)

        log(host, "Recording active color #{rollback_color.slug}")
        record_active_color(host, rollback_color)

        audit_logger.record(host, "rollback", "to #{rollback_color.slug}")
      end

      private def ensure_container_running(host : String, container_name : String) : Nil
        return if container_running?(host, container_name)

        log(host, "Starting rollback target #{container_name}")
        command = ["podman", "start", container_name]
        start_result = run_ssh(host, command)
        return if start_result.exit_code.zero?

        raise Deploy::RollbackFailed.new(
          ssh_command_failed(host, command, start_result).message || "Rollback failed"
        )
      end

      private def switch_proxy(
        host : String,
        proxy : Config::ServerProxyConfig,
        color : Quadlet::Color,
      ) : Nil
        log(host, "Switching proxy traffic to #{service_name(color)}")
        command = proxy_deploy_command(proxy, color)
        deploy_result = run_ssh(host, command)
        return if deploy_result.exit_code.zero?

        raise Deploy::RollbackFailed.new(
          ssh_command_failed(host, command, deploy_result).message || "Rollback failed"
        )
      end

      private def web_proxy : Config::ServerProxyConfig
        server_config("web").proxy || raise Deploy::RollbackFailed.new("Missing proxy configuration for role: web")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
