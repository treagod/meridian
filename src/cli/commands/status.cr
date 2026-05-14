module Meridian
  module CLI
    module Commands
      class Status < Command
        @file = "deploy.yml"
        @selector = TargetSelector.new

        def name : String
          "status"
        end

        def summary : String
          "Show blue/green service state"
        end

        def usage : String
          "Usage: meridian status [options]"
        end

        def description : String
          "Show blue/green service state for the configured hosts."
        end

        def configure(parser : OptionParser) : Nil
          @selector.register(parser)
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError.as(Exception.class)]
        end

        def failure_message : String
          "Status failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          targets = @selector.resolve(config)
          ::Meridian::Commands::Status.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run(targets)
          0
        end
      end
    end
  end
end
