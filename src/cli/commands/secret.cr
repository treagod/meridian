module Meridian
  module CLI
    module Commands
      class Secret < GroupCommand
        def name : String
          "secret"
        end

        def summary : String
          "Manage Podman secrets per role"
        end

        def usage : String
          "Usage: meridian secret SUBCOMMAND NAME [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"set", "Create or replace a secret on target hosts"},
            {"rm", "Remove a secret from target hosts"},
            {"ls", "List secrets on target hosts"},
          ]
        end

        def failure_message : String
          "Secret command failed"
        end
      end

      class SecretSet < Command
        @value : String? = nil
        @role = "web"
        @file = "deploy.yml"

        def name : String
          "secret set"
        end

        def summary : String
          "Create or replace a secret on target hosts"
        end

        def usage : String
          "Usage: meridian secret set NAME [options]"
        end

        def description : String
          String.build do |io|
            io.puts "Create or replace a Podman secret on every host in the target role."
            io.print "When --value is omitted, the secret value is read from stdin."
          end
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
          parser.on("--value VALUE", "Secret value (default: read from stdin)") { |v| @value = v }
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing secret name"
            return 1
          end

          secret_value = @value || ctx.input.gets_to_end.chomp
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).set(positionals.first, secret_value, @role)
          0
        end
      end

      class SecretRm < Command
        @role = "web"
        @file = "deploy.yml"

        def name : String
          "secret rm"
        end

        def summary : String
          "Remove a secret from target hosts"
        end

        def usage : String
          "Usage: meridian secret rm NAME [options]"
        end

        def description : String
          "Remove a Podman secret from every host in the target role."
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
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          if positionals.empty?
            ctx.error.puts "Missing secret name"
            return 1
          end

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).rm(positionals.first, @role)
          0
        end
      end

      class SecretLs < Command
        @role = "web"
        @file = "deploy.yml"

        def name : String
          "secret ls"
        end

        def summary : String
          "List secrets on target hosts"
        end

        def usage : String
          "Usage: meridian secret ls [options]"
        end

        def description : String
          "List Podman secrets on every host in the target role."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--role ROLE", "Target role (default: web)") { |v| @role = v }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError, SSH::CommandFailed, SSH::ConnectionError] of Exception.class
        end

        def failure_message : String
          "Secret command failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Secret.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).ls(@role)
          0
        end
      end
    end
  end
end
