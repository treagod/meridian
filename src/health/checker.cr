require "http/client"
require "uri"

module Meridian
  module Health
    abstract class Transport
      abstract def get(uri : URI, timeout : Time::Span) : HTTP::Client::Response
    end

    class HTTPTransport < Transport
      def get(uri : URI, timeout : Time::Span) : HTTP::Client::Response
        HTTP::Client.new(uri) do |client|
          client.connect_timeout = timeout
          client.read_timeout = timeout
          client.get(uri.request_target)
        end
      end
    end

    class SSHTransport < Transport
      def initialize(@host : String, @ssh_executor : SSH::Executor)
      end

      def get(uri : URI, timeout : Time::Span) : HTTP::Client::Response
        result = @ssh_executor.run(@host, curl_command(uri, timeout))
        raise IO::Error.new(remote_error_message(result)) unless result.exit_code.zero?

        status_code = result.stdout.strip.to_i?
        raise IO::Error.new("Remote health check returned an invalid status for #{uri}") unless status_code

        HTTP::Client::Response.new(status_code)
      rescue ex : SSH::ConnectionError
        raise IO::Error.new(ex.message || "Remote health check failed")
      end

      private def curl_command(uri : URI, timeout : Time::Span) : Array(String)
        timeout_seconds = (timeout.total_milliseconds / 1000.0).to_s

        [
          "curl",
          "--silent",
          "--show-error",
          "--output",
          "/dev/null",
          "--write-out",
          "%{http_code}",
          "--connect-timeout",
          timeout_seconds,
          "--max-time",
          timeout_seconds,
          uri.to_s,
        ]
      end

      private def remote_error_message(result : SSH::Result) : String
        stderr = result.stderr.strip
        return stderr unless stderr.empty?

        stdout = result.stdout.strip
        return stdout unless stdout.empty?

        "Remote health check failed with exit code #{result.exit_code}"
      end
    end

    class Checker
      def initialize(
        @output : IO = STDOUT,
        @transport : Transport = HTTPTransport.new,
        @sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration },
      )
      end

      def poll(
        url : String,
        *,
        interval : Time::Span = 2.seconds,
        timeout : Time::Span = 5.seconds,
        retries : Int32 = 10,
      ) : Bool
        raise ArgumentError.new("retries must be at least 1") if retries < 1

        uri = URI.parse(url)
        last_error = nil

        retries.times do |attempt|
          attempt_number = attempt + 1
          @output.puts "Health check attempt #{attempt_number}/#{retries}: #{url}"

          begin
            response = @transport.get(uri, timeout)
            if response.status_code == 200
              @output.puts "Health check passed: #{url}"
              return true
            end

            last_error = CheckFailed.new("Health check failed with status #{response.status_code} for #{url}")
          rescue ex : IO::Error
            last_error = CheckFailed.new("Health check failed for #{url}: #{ex.message || ex.class.name}")
          end

          @sleeper.call(interval) if attempt < retries - 1
        end

        raise(last_error || CheckFailed.new("Health check failed for #{url}"))
      end
    end
  end
end
