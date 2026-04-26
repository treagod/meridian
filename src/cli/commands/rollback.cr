module Meridian
  module CLI
    module Commands
      class Rollback < Command
        @file = "deploy.yml"

        def name : String
          "rollback"
        end

        def summary : String
          "Switch kamal-proxy back to the inactive color"
        end

        def usage : String
          "Usage: meridian rollback [options]"
        end

        def description : String
          "Switch kamal-proxy back to the inactive color on each web host."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [::Meridian::Deploy::RollbackFailed.as(Exception.class)]
        end

        def failure_message : String
          "Rollback failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Rollback.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run
          0
        end
      end
    end
  end
end
