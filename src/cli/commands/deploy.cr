module Meridian
  module CLI
    module Commands
      class Deploy < Command
        @file = Meridian::Paths::CONFIG_FILE
        @selector = TargetSelector.new

        def name : String
          "deploy"
        end

        def summary : String
          "Deploy the configured application"
        end

        def usage : String
          "Usage: meridian deploy [options]"
        end

        def description : String
          "Deploy the configured application."
        end

        def configure(parser : OptionParser) : Nil
          @selector.register(parser, primary: false)
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [
            ::Meridian::Deploy::DeployFailed,
            ArgumentError,
            ::Meridian::Lock::LockHeld,
            ::Meridian::Lock::LockError,
          ] of Exception.class
        end

        def failure_message : String
          "Deploy failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          targets = @selector.empty? ? nil : @selector.resolve(config)
          orchestrator = ctx.orchestrator_factory.call(config, ctx.ssh_executor, ctx.output)
          orchestrator.deploy(targets)
          0
        end
      end
    end
  end
end
