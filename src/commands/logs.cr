module Meridian
  module Commands
    class Logs < Base
      private record StreamResult,
        host : String,
        exit_code : Int32,
        error : SSH::ConnectionError?

      private class PrefixedIO < IO
        def initialize(@target : IO, @prefix : String, @mutex : Mutex)
          @line_start = true
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("Read is not supported")
        end

        def write(slice : Bytes) : Nil
          @mutex.synchronize do
            String.new(slice).each_char do |char|
              if @line_start
                @target << @prefix
                @line_start = false
              end

              @target << char
              @line_start = char == '\n'
            end

            @target.flush
          end
        end

        def flush : Nil
          @target.flush
        end

        def close : Nil
        end

        def closed? : Bool
          false
        end
      end

      def run(host : String? = nil) : Int32
        if target_host = host
          validate_host!(target_host)
          return stream_ssh(target_host, journalctl_command)
        end

        hosts = all_hosts.sort
        results = Channel(StreamResult).new(hosts.size)
        mutex = Mutex.new

        hosts.each do |stream_host|
          spawn do
            begin
              exit_code = stream_ssh(
                stream_host,
                journalctl_command,
                output: PrefixedIO.new(@output, "[#{stream_host}] ", mutex),
                error: PrefixedIO.new(@error, "[#{stream_host}] ", mutex)
              )
              results.send(StreamResult.new(host: stream_host, exit_code: exit_code, error: nil))
            rescue ex : SSH::ConnectionError
              results.send(StreamResult.new(host: stream_host, exit_code: 255, error: ex))
            end
          end
        end

        first_failure = 0

        hosts.size.times do
          result = results.receive
          if error = result.error
            raise error
          end

          if first_failure.zero? && !result.exit_code.zero?
            first_failure = result.exit_code
          end
        end

        first_failure
      end

      private def journalctl_command : Array(String)
        [
          "journalctl",
          "--user",
          "-u",
          service_unit(Quadlet::Color::Blue),
          "-u",
          service_unit(Quadlet::Color::Green),
          "-f",
          "--no-pager",
        ]
      end

      private def validate_host!(host : String) : Nil
        return if all_hosts.includes?(host)

        raise ArgumentError.new("Unknown host: #{host}")
      end
    end
  end
end
