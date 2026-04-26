module Meridian
  module CLI
    module Commands
      class Logs < Command
        @host : String? = nil
        @file = "deploy.yml"

        def name : String
          "logs"
        end

        def summary : String
          "Stream journalctl logs for the deployed service"
        end

        def usage : String
          "Usage: meridian logs [options]"
        end

        def description : String
          "Stream journalctl logs for the deployed service."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--host HOST", "Configured host to stream logs from") { |value| @host = value }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |value| @file = value }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Logs failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Logs.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run(@host)
        end
      end
    end
  end
end
