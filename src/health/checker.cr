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
