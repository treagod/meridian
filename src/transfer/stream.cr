require "process/executable_path"

module Meridian
  module Transfer
    class Stream
      REMOTE_LOAD_COMMAND = "zstd --decompress --stdout | podman load"

      record PipelineRequest,
        host : String,
        image : String,
        save_command : Array(String),
        compress_command : Array(String),
        remote_command : String,
        ssh_args : Array(String)

      record PipelineResult,
        bytes_transferred : Int64

      alias DependencyChecker = Proc(String, Bool)
      alias MonotonicClock = Proc(Time::Instant)
      alias PipelineRunner = Proc(PipelineRequest, PipelineResult)

      def initialize(
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        @output : IO = STDOUT,
        @user : String? = nil,
        @port : Int32? = nil,
        @identity_file : String? = nil,
        local_dependency_checker : DependencyChecker? = nil,
        monotonic_clock : MonotonicClock? = nil,
        pipeline_runner : PipelineRunner? = nil,
      )
        @local_dependency_checker = local_dependency_checker || ->(command : String) { !Process.find_executable(command).nil? }
        @monotonic_clock = monotonic_clock || -> { Time.instant }
        @pipeline_runner = pipeline_runner || ->(request : PipelineRequest) { execute_pipeline(request) }
      end

      def transfer(host : String, image : String) : Nil
        ensure_local_dependency!("zstd")
        ensure_remote_dependency!(host, "zstd")

        request = PipelineRequest.new(
          host: host,
          image: image,
          save_command: ["podman", "save", image],
          compress_command: ["zstd", "--stdout"],
          remote_command: REMOTE_LOAD_COMMAND,
          ssh_args: @ssh_executor.command_args(
            host,
            REMOTE_LOAD_COMMAND,
            user: @user,
            port: @port,
            identity_file: @identity_file
          )
        )

        print_line(host, "Streaming image #{image}")
        started_at = @monotonic_clock.call
        result = @pipeline_runner.call(request)
        elapsed = @monotonic_clock.call - started_at
        print_line(host, "Transferred #{result.bytes_transferred} bytes in #{format_duration(elapsed)}")
      rescue ex : DependencyMissing
        raise ex
      rescue ex : SSH::ConnectionError
        raise TransferFailed.new(ex.message || "Image transfer to #{host} failed")
      rescue ex : IO::Error
        raise TransferFailed.new(ex.message || "Image transfer to #{host} failed")
      end

      private def ensure_local_dependency!(dependency : String) : Nil
        return if @local_dependency_checker.call(dependency)

        raise DependencyMissing.new("Missing local dependency: #{dependency}")
      end

      private def ensure_remote_dependency!(host : String, dependency : String) : Nil
        result = @ssh_executor.run(
          host,
          ["sh", "-lc", "command -v #{Process.quote_posix(dependency)} >/dev/null"],
          user: @user,
          port: @port,
          identity_file: @identity_file
        )
        return if result.exit_code.zero?

        raise DependencyMissing.new("Missing remote dependency on #{host}: #{dependency}")
      rescue ex : SSH::ConnectionError
        raise TransferFailed.new(ex.message || "Image transfer to #{host} failed")
      end

      private def execute_pipeline(request : PipelineRequest) : PipelineResult
        save_error = IO::Memory.new
        zstd_error = IO::Memory.new
        ssh_output = IO::Memory.new
        ssh_error = IO::Memory.new
        save, zstd, ssh = start_pipeline(request, save_error, zstd_error, ssh_output, ssh_error)

        copy_error = nil.as(Exception?)
        bytes_transferred =
          begin
            copy_and_count(zstd.output, ssh.input)
          rescue ex : Exception
            copy_error = ex
            0_i64
          end

        save_status = save.wait
        zstd_status = zstd.wait
        ssh_status = ssh.wait

        ensure_success!("podman save", save_status, save_error.to_s)
        ensure_success!("zstd", zstd_status, zstd_error.to_s)
        ensure_success!("ssh", ssh_status, ssh_error.to_s, ssh_output.to_s)

        if error = copy_error
          raise TransferFailed.new(error.message || error.class.name)
        end

        PipelineResult.new(bytes_transferred: bytes_transferred)
      end

      private def start_pipeline(
        request : PipelineRequest,
        save_error : IO,
        zstd_error : IO,
        ssh_output : IO,
        ssh_error : IO,
      ) : {Process, Process, Process}
        begin
          save = Process.new(
            request.save_command.first,
            request.save_command[1..],
            output: Process::Redirect::Pipe,
            error: save_error
          )
        rescue ex : IO::Error
          raise TransferFailed.new(ex.message || "Failed to start transfer pipeline")
        end

        begin
          zstd = Process.new(
            request.compress_command.first,
            request.compress_command[1..],
            input: save.output,
            output: Process::Redirect::Pipe,
            error: zstd_error
          )
        rescue ex : IO::Error
          terminate(save)
          raise TransferFailed.new(ex.message || "Failed to start transfer pipeline")
        end

        begin
          ssh = Process.new(
            "ssh",
            request.ssh_args,
            input: Process::Redirect::Pipe,
            output: ssh_output,
            error: ssh_error
          )
        rescue ex : IO::Error
          terminate(save)
          terminate(zstd)
          raise TransferFailed.new(ex.message || "Failed to start transfer pipeline")
        end

        {save, zstd, ssh}
      end

      private def ensure_success!(
        command : String,
        status : Process::Status,
        stderr : String,
        stdout : String = "",
      ) : Nil
        return if status.success?

        raise transfer_failed(command, status, stderr, stdout)
      end

      private def copy_and_count(src : IO, dst : IO) : Int64
        buffer = Bytes.new(64 * 1024)
        total = 0_i64

        begin
          loop do
            bytes_read = src.read(buffer)
            break if bytes_read.zero?

            dst.write(buffer[0, bytes_read])
            total += bytes_read
          end

          dst.flush
          total
        ensure
          src.close rescue nil
          dst.close rescue nil
        end
      end

      private def transfer_failed(command : String, status : Process::Status, stderr : String, stdout : String = "") : TransferFailed
        details = stderr.strip
        details = stdout.strip if details.empty?
        details = "exit code #{status.exit_code}" if details.empty?
        TransferFailed.new("#{command} failed with exit code #{status.exit_code}: #{details}")
      end

      private def terminate(process : Process?) : Nil
        return unless process

        process.terminate(graceful: false)
      rescue
        nil
      end

      private def print_line(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end

      private def format_duration(duration : Time::Span) : String
        if duration < 1.second
          "#{duration.total_milliseconds.round(1)}ms"
        else
          "#{duration.total_seconds.round(2)}s"
        end
      end
    end
  end
end
