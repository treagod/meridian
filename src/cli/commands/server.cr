module Meridian
  module CLI
    module Commands
      class Server < GroupCommand
        def name : String
          "server"
        end

        def summary : String
          "Provision and manage servers"
        end

        def usage : String
          "Usage: meridian server SUBCOMMAND [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"bootstrap", "Provision a fresh server for Meridian deploys"},
          ]
        end

        def failure_message : String
          "Server command failed"
        end
      end

      class ServerBootstrap < Command
        @host : String? = nil
        @port : Int32? = nil
        @root_user = "root"
        @deploy_user : String? = nil
        @accept_new_host_key = true
        @enable_auto_updates = true
        @passwordless_sudo = true
        @rootless_low_ports = true
        @rootless_port_start = 80
        @file = "deploy.yml"

        def name : String
          "server bootstrap"
        end

        def summary : String
          "Provision a fresh server for Meridian deploys"
        end

        def usage : String
          "Usage: meridian server bootstrap --host HOST [options]"
        end

        def description : String
          String.build do |io|
            io.puts "Provision a fresh Debian/Ubuntu server: installs Podman, UFW, and transfer tools"
            io.puts "for the configured transfer mode, creates the deploy user and rootless directories,"
            io.print "installs your SSH public key, then hardens SSH."
          end
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--host HOST", "Server IP or hostname (inferred if only one host in deploy.yml)") { |v| @host = v }
          parser.on("--port PORT", "SSH port (overrides deploy.yml default)") { |v| @port = v.to_i }
          parser.on("--root-user USER", "Initial privileged SSH user (default: root)") { |v| @root_user = v }
          parser.on("--deploy-user USER", "User to create (default: from deploy.yml ssh.user)") { |v| @deploy_user = v }
          parser.on("--accept-new-host-key", "Trust new host keys (default)") { @accept_new_host_key = true }
          parser.on("--no-accept-new-host-key", "Require known host key") { @accept_new_host_key = false }
          parser.on("--enable-auto-updates BOOL", "Unattended security updates (default: yes)") do |v|
            @enable_auto_updates = parse_bool_flag(v, "--enable-auto-updates")
          end
          parser.on("--passwordless-sudo BOOL", "Passwordless sudo for deploy user (default: yes)") do |v|
            @passwordless_sudo = parse_bool_flag(v, "--passwordless-sudo")
          end
          parser.on("--rootless-low-ports BOOL", "Allow rootless low-port binding (default: yes)") do |v|
            @rootless_low_ports = parse_bool_flag(v, "--rootless-low-ports")
          end
          parser.on("--rootless-port-start PORT", "Lowest unprivileged port (default: 80)") { |v| @rootless_port_start = v.to_i }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [::Meridian::Server::BootstrapError.as(Exception.class)]
        end

        def failure_message : String
          "Server bootstrap failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          invocation = ServerBootstrapInvocation.new(
            host: @host,
            port: @port,
            root_user: @root_user,
            deploy_user: @deploy_user,
            accept_new_host_key: @accept_new_host_key,
            enable_auto_updates: @enable_auto_updates,
            passwordless_sudo: @passwordless_sudo,
            rootless_low_ports: @rootless_low_ports,
            rootless_port_start: @rootless_port_start,
            file: @file,
          )

          config = Config::Loader.load(@file)
          ::Meridian::Commands::Server.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output, error: ctx.error).bootstrap(invocation)
          0
        end

        private def parse_bool_flag(value : String, flag : String) : Bool
          case value.strip.downcase
          when "1", "true", "yes", "y", "on"  then true
          when "0", "false", "no", "n", "off" then false
          else
            raise ParseError.new("#{flag} must be one of: yes/no, true/false, 1/0")
          end
        end
      end
    end
  end
end
