module Meridian
  module CLI
    module Commands
      class Logs < Command
        @file = "deploy.yml"
        @selector = TargetSelector.new

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
          @selector.register(parser)
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
          hosts = @selector.resolve(config).map(&.host)
          hosts.uniq!
          ::Meridian::Commands::Logs.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run(hosts)
        end
      end
    end
  end
end
