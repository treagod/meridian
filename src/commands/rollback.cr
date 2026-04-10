module Meridian
  module Commands
    class Rollback < Base
      def run : Nil
        proxy = web_proxy

        hosts_for_role("web").sort.each do |host|
          current_color = stored_active_color(host) || raise Deploy::RollbackFailed.new("No active color recorded on #{host}")
          rollback_color = inactive_color(current_color)
          rollback_target = service_name(rollback_color)

          unless container_exists?(host, rollback_target)
            raise Deploy::RollbackFailed.new("Rollback target #{rollback_target} is not present on #{host}")
          end

          unless container_running?(host, rollback_target)
            log(host, "Starting rollback target #{rollback_target}")
            start_result = run_ssh(host, ["podman", "start", rollback_target])
            unless start_result.exit_code.zero?
              raise Deploy::RollbackFailed.new(ssh_command_failed(host, start_result.exit_code).message || "Rollback failed")
            end
          end

          log(host, "Switching proxy traffic to #{rollback_target}")
          deploy_result = run_ssh(host, proxy_deploy_command(proxy, rollback_color))
          unless deploy_result.exit_code.zero?
            raise Deploy::RollbackFailed.new(ssh_command_failed(host, deploy_result.exit_code).message || "Rollback failed")
          end

          log(host, "Recording active color #{rollback_color.slug}")
          upload_ssh(host, ACTIVE_COLOR_FILE, "#{rollback_color.slug}\n")
        end
      rescue ex : Config::UnknownRole | ArgumentError | SSH::CommandFailed | SSH::ConnectionError
        raise Deploy::RollbackFailed.new(ex.message || "Rollback failed")
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
