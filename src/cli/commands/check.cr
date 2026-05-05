module Meridian
  module CLI
    module Commands
      class Check < Command
        @file = "deploy.yml"

        def name : String
          "check"
        end

        def summary : String
          "Verify remote hosts before deploy"
        end

        def usage : String
          "Usage: meridian check [options]"
        end

        def description : String
          "Verify SSH connectivity, host dependencies, secrets, and proxy state without modifying remote hosts."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError.as(Exception.class)]
        end

        def failure_message : String
          "Check failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          passed = ::Meridian::Commands::Check.new(
            config,
            ssh_executor: ctx.ssh_executor,
            output: ctx.output,
            error: ctx.error
          ).run
          passed ? 0 : 1
        end
      end
    end
  end
end
