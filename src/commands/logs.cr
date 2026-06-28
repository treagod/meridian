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

      def run(targets : Array(CLI::TargetSelector::Target)) : Int32
        raise ArgumentError.new("No targets to stream") if targets.empty?

        units_by_host = targets.each_with_object(Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }) do |target, acc|
          acc[target.host].concat(units_for_role(target.role))
        end
        units_by_host.each_value(&.uniq!)

        if units_by_host.size == 1
          host, units = units_by_host.first
          return stream_ssh(host, journalctl_command(units))
        end

        unique_hosts = units_by_host.keys.sort!
        results = Channel(StreamResult).new(unique_hosts.size)
        mutex = Mutex.new

        unique_hosts.each do |stream_host|
          spawn do
            begin
              exit_code = stream_ssh(
                stream_host,
                journalctl_command(units_by_host[stream_host]),
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

        unique_hosts.size.times do
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

      private def units_for_role(role : String) : Array(String)
        server = server_config(role)
        return server.units unless server.managed?

        if server.proxy
          [
            service_unit(Quadlet::Color::Blue),
            service_unit(Quadlet::Color::Green),
          ]
        else
          [role_service_unit(role)]
        end
      end

      private def journalctl_command(units : Array(String)) : Array(String)
        command = [
          "journalctl",
          "--user",
        ]
        units.each do |unit|
          command << "-u"
          command << unit
        end
        command.concat(["-f", "--no-pager"])
      end
    end
  end
end
