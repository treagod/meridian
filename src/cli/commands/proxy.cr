module Meridian
  module CLI
    module Commands
      class Proxy < GroupCommand
        def name : String
          "proxy"
        end

        def summary : String
          "Manage kamal-proxy"
        end

        def usage : String
          "Usage: meridian proxy SUBCOMMAND [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"remove", "Stop and remove kamal-proxy"},
          ]
        end

        def failure_message : String
          "Proxy command failed"
        end
      end

      class ProxyRemove < Command
        @file = "deploy.yml"

        def name : String
          "proxy remove"
        end

        def summary : String
          "Stop and remove kamal-proxy"
        end

        def usage : String
          "Usage: meridian proxy remove [options]"
        end

        def description : String
          "Stop and remove kamal-proxy from web hosts."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [::Meridian::Proxy::RemoveFailed.as(Exception.class)]
        end

        def failure_message : String
          "Proxy command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          manager = ctx.proxy_manager_factory.call(config, ctx.ssh_executor, ctx.output)
          manager.remove
          0
        end
      end
    end
  end
end
