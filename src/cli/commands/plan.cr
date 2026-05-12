module Meridian
  module CLI
    module Commands
      class Plan < Command
        @file = "deploy.yml"

        def name : String
          "plan"
        end

        def summary : String
          "Print the resolved deploy plan"
        end

        def usage : String
          "Usage: meridian plan [options]"
        end

        def description : String
          "Print the resolved deploy intent from deploy.yml without contacting any host."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |value| @file = value }
        end

        def failure_message : String
          "Failed to render plan"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Plan.new(config, output: ctx.output).run
          0
        end
      end
    end
  end
end
