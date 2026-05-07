module Meridian
  module Commands
    class Server < Base
      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor,
        output : IO = STDOUT,
        error : IO = STDERR,
        @bootstrap_runner : Meridian::Server::Bootstrapper::Runner = Meridian::Server::Bootstrapper::ProcessRunner.new,
      )
        super(config, ssh_executor: ssh_executor, output: output, error: error)
      end

      def bootstrap(invocation : CLI::ServerBootstrapInvocation) : Nil
        host = invocation.host || resolve_single_host
        private_key = config.ssh.keys.first? ||
                      raise Meridian::Server::BootstrapError.new(
                        "No SSH keys configured in deploy.yml — add at least one path under ssh.keys"
                      )
        pub = "#{private_key}.pub"
        raise Meridian::Server::BootstrapError.new("Public key file not found: #{pub}") unless File.exists?(pub)

        bc = Meridian::Server::BootstrapConfig.new(
          host: host,
          port: invocation.port || config.ssh.port,
          root_user: invocation.root_user,
          deploy_user: invocation.deploy_user || config.ssh.user,
          public_key_file: pub,
          private_key_file: private_key,
          accept_new_host_key: invocation.accept_new_host_key,
          enable_auto_updates: invocation.enable_auto_updates,
          passwordless_sudo: invocation.passwordless_sudo,
          rootless_low_ports: invocation.rootless_low_ports,
          rootless_port_start: invocation.rootless_port_start,
          transfer_mode: config.transfer.try(&.mode),
        )
        Meridian::Server::Bootstrapper.new(bc, runner: @bootstrap_runner, output: @output).bootstrap
      end

      private def resolve_single_host : String
        hosts = config.servers.values.flat_map(&.hosts).uniq
        if hosts.size == 1
          hosts.first
        else
          raise Meridian::Server::BootstrapError.new(
            "Multiple hosts configured — specify one with --host"
          )
        end
      end
    end
  end
end
