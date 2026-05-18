module Meridian
  module Commands
    class Secret < Base
      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        output : IO = STDOUT,
        error : IO = STDERR,
      )
        super(config, ssh_executor: ssh_executor, output: output, error: error)
      end

      def set(name : String, value : String, role : String = "web") : Nil
        hosts = hosts_for_role(role)
        hosts.each do |host|
          log(host, "Setting secret #{name}")
          run_ssh!(host, ["podman", "secret", "rm", "-i", name])
          run_ssh!(host, ["podman", "secret", "create", name, "-"], value)
        end
      end

      def rm(name : String, role : String = "web") : Nil
        hosts = hosts_for_role(role)
        hosts.each do |host|
          log(host, "Removing secret #{name}")
          run_ssh!(host, ["podman", "secret", "rm", name])
        end
      end

      def ls(role : String = "web") : Nil
        hosts = hosts_for_role(role)
        hosts.each do |host|
          log(host, "Listing secrets")
          result = run_ssh!(host, ["podman", "secret", "ls"])
          @output.puts result.stdout
        end
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
