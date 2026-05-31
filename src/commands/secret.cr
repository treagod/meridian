require "base64"

module Meridian
  module Commands
    class Secret < Base
      enum GeneratedSecretFormat
        Hex
        Base64
        Base64url

        def self.parse(value : String) : self
          case value
          when "hex"
            Hex
          when "base64"
            Base64
          when "base64url"
            Base64url
          else
            raise ArgumentError.new("Unknown secret format: #{value}")
          end
        end

        def encode(bytes : Bytes) : String
          case self
          in .hex?
            bytes.hexstring
          in .base64?
            ::Base64.strict_encode(bytes)
          in .base64url?
            ::Base64.urlsafe_encode(bytes, padding: false)
          end
        end
      end

      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        output : IO = STDOUT,
        error : IO = STDERR,
      )
        super(config, ssh_executor: ssh_executor, output: output, error: error)
      end

      def self.generate_value(length : Int32 = 32, format : GeneratedSecretFormat = GeneratedSecretFormat::Hex) : String
        raise ArgumentError.new("Secret length must be greater than 0") unless length > 0

        bytes = Random::Secure.random_bytes(length)
        format.encode(bytes)
      end

      def gen(
        name : String,
        role : String = "web",
        length : Int32 = 32,
        format : GeneratedSecretFormat = GeneratedSecretFormat::Hex,
        force : Bool = false,
      ) : Nil
        existing_hosts = existing_hosts_for(name, role)
        unless force || existing_hosts.empty?
          raise SecretExists.new("Secret #{name} already exists on: #{existing_hosts.join(", ")}. Pass --force to rotate it.")
        end

        set(name, self.class.generate_value(length, format), role)
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

      def existing_hosts_for(name : String, role : String = "web") : Array(String)
        hosts_for_role(role).select do |host|
          run_ssh(host, ["podman", "secret", "inspect", name]).exit_code.zero?
        end
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
