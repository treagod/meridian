module Meridian
  module CLI
    module Commands
      class Prune < Command
        @file = Meridian::Paths::CONFIG_FILE
        @force = false

        def name : String
          "prune"
        end

        def summary : String
          "Remove stale generated files from hosts"
        end

        def usage : String
          "Usage: meridian prune [options]"
        end

        def description : String
          "Remove generated files that are no longer in the config. " \
          "Podman volumes are kept."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
          parser.on("--force", "Remove without asking for confirmation") { @force = true }
        end

        def rescuable : Array(Exception.class)
          super + [
            ArgumentError,
            SSH::CommandFailed,
            SSH::ConnectionError,
          ] of Exception.class
        end

        def failure_message : String
          "Prune failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Prune.new(
            config,
            ssh_executor: ctx.ssh_executor,
            output: ctx.output,
            error: ctx.error,
            input: ctx.input
          ).run(force: @force)
          0
        end
      end
    end
  end
end
