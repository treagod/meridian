module Meridian
  module CLI
    module Commands
      class Exec < Command
        @file = "deploy.yml"
        @selector = TargetSelector.new

        def name : String
          "exec"
        end

        def summary : String
          "Run a command inside the active container for a role"
        end

        def usage : String
          "Usage: meridian exec ROLE [options] -- COMMAND [ARGS...]"
        end

        def description : String
          "Run a command inside the active container for a configured role."
        end

        def stop_at_separator? : Bool
          true
        end

        def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
          first = args.first?
          if first.nil? || first.starts_with?('-')
            {[] of String, args}
          else
            {[first], args.size > 1 ? args[1..] : [] of String}
          end
        end

        def configure(parser : OptionParser) : Nil
          @selector.register(parser, role: false, primary: false)
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |value| @file = value }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Exec failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing required role"
            return 1
          end

          if remote_command.empty?
            ctx.error.puts "Missing command after --"
            return 1
          end

          role = positionals.first
          config = Config::Loader.load(@file)
          host = resolve_target_host(config, role)
          ::Meridian::Commands::Exec.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run(
            role,
            remote_command,
            host
          )
        end

        private def resolve_target_host(config : Config::DeployConfig, role : String) : String
          @selector.role = role
          @selector.resolve(config).first.host
        end
      end
    end
  end
end
