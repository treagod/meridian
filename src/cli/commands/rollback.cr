module Meridian
  module CLI
    module Commands
      class Rollback < Command
        @file = Meridian::Paths::CONFIG_FILE

        def name : String
          "rollback"
        end

        def summary : String
          "Restore the previously deployed release"
        end

        def usage : String
          "Usage: meridian rollback [options]"
        end

        def description : String
          "Reconstruct the previous release from recorded release state on each web host, health-check it, then switch kamal-proxy back to it."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
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
