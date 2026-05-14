module Meridian
  module CLI
    module Commands
      class Run < Command
        @file = "deploy.yml"
        @selector = TargetSelector.new

        def name : String
          "run"
        end

        def summary : String
          "Run a one-off command in an isolated container"
        end

        def usage : String
          "Usage: meridian run ROLE [options] -- COMMAND [ARGS...]"
        end

        def description : String
          String.build do |io|
            io.puts "Run a one-off command in an isolated container for a configured role."
            io.print "Unlike exec, this starts a new container with --rm and does not affect the live service."
          end
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
          "Run failed"
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
          ::Meridian::Commands::Run.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).run(
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
