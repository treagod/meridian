module Meridian
  module SSH
    record Result, exit_code : Int32, stdout : String, stderr : String

    class Executor
      abstract class Runner
        abstract def run(command : String, args : Array(String), input : String? = nil) : Result
      end

      class ProcessRunner < Runner
        def run(command : String, args : Array(String), input : String? = nil) : Result
          stdout = IO::Memory.new
          stderr = IO::Memory.new

          status = if input
                     Process.run(
                       command,
                       args,
                       input: IO::Memory.new(input),
                       output: stdout,
                       error: stderr
                     )
                   else
                     Process.run(command, args, output: stdout, error: stderr)
                   end

          Result.new(exit_code: status.exit_code, stdout: stdout.to_s, stderr: stderr.to_s)
        end
      end

      def initialize(@runner : Runner = ProcessRunner.new)
      end

      def run(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
      ) : Result
        result = @runner.run("ssh", ssh_args(host, command, env, user, port, identity_file))
        raise ConnectionError.new("SSH connection to #{target_host(host, user)} failed") if result.exit_code == 255

        result
      end

      def run!(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
      ) : Result
        result = run(host, command, env: env, user: user, port: port, identity_file: identity_file)
        return result if result.exit_code.zero?

        raise CommandFailed.new("Remote command on #{target_host(host, user)} failed with exit code #{result.exit_code}")
      end

      def upload(
        host : String,
        remote_path : String,
        content : String,
        *,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
      ) : Nil
        result = @runner.run(
          "ssh",
          ssh_args(host, "cat > #{Process.quote_posix(remote_path)}", user, port, identity_file),
          input: content
        )

        raise ConnectionError.new("SSH connection to #{target_host(host, user)} failed") if result.exit_code == 255
        return if result.exit_code.zero?

        raise CommandFailed.new("Upload to #{target_host(host, user)}:#{remote_path} failed with exit code #{result.exit_code}")
      end

      private def ssh_args(
        host : String,
        command : Array(String),
        env : Hash(String, String),
        user : String?,
        port : Int32?,
        identity_file : String?,
      ) : Array(String)
        ssh_args(host, build_remote_command(command, env), user, port, identity_file)
      end

      private def ssh_args(
        host : String,
        remote_command : String,
        user : String?,
        port : Int32?,
        identity_file : String?,
      ) : Array(String)
        args = [] of String

        if port
          args << "-p"
          args << port.to_s
        end

        if identity_file
          args << "-i"
          args << identity_file
        end

        args << target_host(host, user)
        args << remote_command
        args
      end

      private def build_remote_command(command : Array(String), env : Hash(String, String)) : String
        String.build do |io|
          env.each do |key, value|
            io << key << '=' << Process.quote_posix(value) << ' '
          end
          io << Process.quote_posix(command)
        end
      end

      private def target_host(host : String, user : String?) : String
        return host unless user

        "#{user}@#{host}"
      end
    end
  end
end
