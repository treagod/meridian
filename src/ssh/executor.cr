module Meridian
  module SSH
    record Result, exit_code : Int32, stdout : String, stderr : String

    class Executor
      abstract class Runner
        abstract def run(command : String, args : Array(String), input : String? = nil) : Result
      end

      abstract class StreamingRunner
        abstract def run(command : String, args : Array(String), input : IO, output : IO, error : IO) : Int32
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

      class ProcessStreamingRunner < StreamingRunner
        def run(command : String, args : Array(String), input : IO, output : IO, error : IO) : Int32
          Process.run(command, args, input: input, output: output, error: error).exit_code
        end
      end

      def initialize(
        @runner : Runner = ProcessRunner.new,
        @streaming_runner : StreamingRunner = ProcessStreamingRunner.new,
      )
      end

      def command_args(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Array(String)
        ssh_args(
          host,
          command,
          env,
          user,
          port,
          identity_file,
          proxy_jump,
          connect_timeout,
          keepalive,
          keepalive_interval
        )
      end

      def command_args(
        host : String,
        remote_command : String,
        *,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Array(String)
        ssh_args(
          host,
          remote_command,
          user,
          port,
          identity_file,
          proxy_jump,
          connect_timeout,
          keepalive,
          keepalive_interval
        )
      end

      def run(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        input : String? = nil,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Result
        result = @runner.run(
          "ssh",
          command_args(
            host,
            command,
            env: env,
            user: user,
            port: port,
            identity_file: identity_file,
            proxy_jump: proxy_jump,
            connect_timeout: connect_timeout,
            keepalive: keepalive,
            keepalive_interval: keepalive_interval
          ),
          input
        )
        raise ConnectionError.new("SSH connection to #{target_host(host, user)} failed") if result.exit_code == 255

        result
      end

      def stream(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        input : IO = STDIN,
        output : IO = STDOUT,
        error : IO = STDERR,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Int32
        exit_code = @streaming_runner.run(
          "ssh",
          command_args(
            host,
            command,
            env: env,
            user: user,
            port: port,
            identity_file: identity_file,
            proxy_jump: proxy_jump,
            connect_timeout: connect_timeout,
            keepalive: keepalive,
            keepalive_interval: keepalive_interval
          ),
          input,
          output,
          error
        )
        raise ConnectionError.new("SSH connection to #{target_host(host, user)} failed") if exit_code == 255

        exit_code
      end

      def run!(
        host : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
        input : String? = nil,
        user : String? = nil,
        port : Int32? = nil,
        identity_file : String? = nil,
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Result
        result = run(
          host,
          command,
          env: env,
          input: input,
          user: user,
          port: port,
          identity_file: identity_file,
          proxy_jump: proxy_jump,
          connect_timeout: connect_timeout,
          keepalive: keepalive,
          keepalive_interval: keepalive_interval
        )
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
        proxy_jump : String? = nil,
        connect_timeout : Int32? = nil,
        keepalive : Bool? = nil,
        keepalive_interval : Int32? = nil,
      ) : Nil
        result = @runner.run(
          "ssh",
          command_args(
            host,
            "cat > #{Process.quote_posix(remote_path)}",
            user: user,
            port: port,
            identity_file: identity_file,
            proxy_jump: proxy_jump,
            connect_timeout: connect_timeout,
            keepalive: keepalive,
            keepalive_interval: keepalive_interval
          ),
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
        proxy_jump : String?,
        connect_timeout : Int32?,
        keepalive : Bool?,
        keepalive_interval : Int32?,
      ) : Array(String)
        ssh_args(
          host,
          build_remote_command(command, env),
          user,
          port,
          identity_file,
          proxy_jump,
          connect_timeout,
          keepalive,
          keepalive_interval
        )
      end

      private def ssh_args(
        host : String,
        remote_command : String,
        user : String?,
        port : Int32?,
        identity_file : String?,
        proxy_jump : String?,
        connect_timeout : Int32?,
        keepalive : Bool?,
        keepalive_interval : Int32?,
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

        if proxy_jump
          args << "-J"
          args << proxy_jump
        end

        if connect_timeout
          args << "-o"
          args << "ConnectTimeout=#{connect_timeout}"
        end

        if keepalive == false
          args << "-o"
          args << "ServerAliveInterval=0"
        elsif keepalive
          args << "-o"
          args << "ServerAliveInterval=#{keepalive_interval || 30}"
          args << "-o"
          args << "ServerAliveCountMax=3"
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
