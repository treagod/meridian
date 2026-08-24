module Meridian
  module CLI
    module Commands
      class Accessory < GroupCommand
        def name : String
          "accessory"
        end

        def summary : String
          "Manage accessory services"
        end

        def usage : String
          "Usage: meridian accessory SUBCOMMAND NAME [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"start", "Upload and start an accessory service"},
            {"stop", "Stop an accessory service"},
            {"remove", "Remove an accessory service unit"},
            {"logs", "Stream logs for an accessory service"},
          ]
        end

        def failure_message : String
          "Accessory command failed"
        end
      end

      abstract class AccessoryAction < Command
        @file = Meridian::Paths::CONFIG_FILE

        def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
          first = args.first?
          if first.nil? || first.starts_with?('-')
            {[] of String, args}
          else
            {[first], args.size > 1 ? args[1..] : [] of String}
          end
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--config PATH", "Path to deploy config (default: .meridian/deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [
            Config::UnknownAccessory,
            ArgumentError,
            SSH::CommandFailed,
            SSH::ConnectionError,
          ] of Exception.class
        end

        def failure_message : String
          "Accessory command failed"
        end

        protected def require_name(ctx : Context, positionals : Array(String)) : String?
          if positionals.empty?
            ctx.error.puts "Missing accessory name"
            return
          end
          positionals.first
        end
      end

      # Lifecycle actions that may disrupt other services sharing the accessory.
      # `--force` acknowledges that shared impact and nothing else.
      abstract class SharedAccessoryAction < AccessoryAction
        @force = false

        def configure(parser : OptionParser) : Nil
          super
          parser.on("--force", "Skip the confirmation when other services share this accessory") { @force = true }
        end

        protected def accessory_command(ctx : Context, config : Config::DeployConfig) : ::Meridian::Commands::Accessory
          ::Meridian::Commands::Accessory.new(
            config,
            ssh_executor: ctx.ssh_executor,
            output: ctx.output,
            error: ctx.error,
            input: ctx.input
          )
        end
      end

      class AccessoryStart < AccessoryAction
        def name : String
          "accessory start"
        end

        def summary : String
          "Upload and start an accessory service"
        end

        def usage : String
          "Usage: meridian accessory start NAME [options]"
        end

        def description : String
          "Upload the accessory Quadlet and start the accessory service."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          accessory_name = require_name(ctx, positionals)
          return 1 unless accessory_name

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Accessory.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).start(accessory_name)
          0
        end
      end

      class AccessoryStop < SharedAccessoryAction
        def name : String
          "accessory stop"
        end

        def summary : String
          "Stop an accessory service"
        end

        def usage : String
          "Usage: meridian accessory stop NAME [options]"
        end

        def description : String
          "Stop the accessory service on its configured host.\n" \
          "Warns first when other services on that host share the accessory."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          accessory_name = require_name(ctx, positionals)
          return 1 unless accessory_name

          config = Config::Loader.load(@file)
          accessory_command(ctx, config).stop(accessory_name, force: @force) ? 0 : 1
        end
      end

      class AccessoryRemove < SharedAccessoryAction
        def name : String
          "accessory remove"
        end

        def summary : String
          "Remove an accessory service unit"
        end

        def usage : String
          "Usage: meridian accessory remove NAME [options]"
        end

        def description : String
          "Stop the accessory and delete its Quadlet unit from the host.\n" \
          "Named volumes, images, and the accessory network are left in place.\n" \
          "Warns first when other services on that host share the accessory."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          accessory_name = require_name(ctx, positionals)
          return 1 unless accessory_name

          config = Config::Loader.load(@file)
          accessory_command(ctx, config).remove(accessory_name, force: @force) ? 0 : 1
        end
      end

      class AccessoryLogs < AccessoryAction
        def name : String
          "accessory logs"
        end

        def summary : String
          "Stream logs for an accessory service"
        end

        def usage : String
          "Usage: meridian accessory logs NAME [options]"
        end

        def description : String
          "Stream journalctl logs for the accessory service."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          accessory_name = require_name(ctx, positionals)
          return 1 unless accessory_name

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Accessory.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).logs(accessory_name)
        end
      end
    end
  end
end
