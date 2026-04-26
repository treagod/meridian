module Meridian
  module CLI
    module Commands
      class Setup < Command
        @file = "deploy.yml"

        def name : String
          "setup"
        end

        def summary : String
          "Install and start kamal-proxy on web hosts"
        end

        def usage : String
          "Usage: meridian setup [options]"
        end

        def description : String
          "Install and start kamal-proxy on web hosts."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [::Meridian::Proxy::SetupFailed.as(Exception.class)]
        end

        def failure_message : String
          "Proxy setup failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          manager = ctx.proxy_manager_factory.call(config, ctx.ssh_executor, ctx.output)
          manager.setup
          0
        end
      end
    end
  end
end
