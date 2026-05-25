module Meridian
  module CLI
    module Commands
      class Audit < Command
        @file = "deploy.yml"
        @host : String? = nil
        @lines = ::Meridian::Commands::Audit::DEFAULT_LIMIT

        def name : String
          "audit"
        end

        def summary : String
          "Show recent audit log entries by host"
        end

        def usage : String
          "Usage: meridian audit [options]"
        end

        def description : String
          "Print recent Meridian audit log entries recorded on each host."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
          parser.on("--host HOST", "Limit to a single configured host") { |v| @host = v }
          parser.on("--lines N", "Entries to show per host (default: #{@lines})") do |v|
            @lines = v.to_i? || raise ParseError.new("Invalid --lines value: #{v}")
          end
        end

        def rescuable : Array(Exception.class)
          super + [
            ArgumentError,
            SSH::CommandFailed,
            SSH::ConnectionError,
          ] of Exception.class
        end

        def failure_message : String
          "Audit command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Audit.new(
            config,
            ssh_executor: ctx.ssh_executor,
            output: ctx.output,
            error: ctx.error
          ).run(@host, @lines)
        end
      end
    end
  end
end
