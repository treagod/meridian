module Meridian
  module Deploy
    # Shared blue/green candidate probe: polls a container through the shared
    # proxy network until `required_successes` consecutive passes, raising
    # Health::CheckFailed once the retry budget is exhausted. Includers provide
    # `run_ssh`, `@output`, and `@health_sleeper`.
    module HealthPolling
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
        required = proxy.healthcheck.required_successes
        host_header = proxy.host || container_name

        consecutive = 0
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
            consecutive += 1
            @output.puts "[#{host}] Health check passed (#{consecutive}/#{required}): #{container_name} -> #{url}"
            return if consecutive >= required
          else
            consecutive = 0
          end

          @health_sleeper.call(interval.seconds) if attempt < retries - 1
        end

        raise Health::CheckFailed.new("Health check failed for #{container_name} -> #{url}: needed #{required} consecutive successes within #{retries} attempts")
      end
    end
  end
end
