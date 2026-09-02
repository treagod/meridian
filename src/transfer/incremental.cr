require "file_utils"
require "process/executable_path"
require "./helpers"

module Meridian
  module Transfer
    class Incremental
      include Helpers
      OCI_ROOT = "/tmp/meridian-oci"

      record LocalCommandRequest,
        command : Array(String),
        env : Hash(String, String)

      record LocalCommandResult,
        exit_code : Int32,
        stdout : String,
        stderr : String

      alias DependencyChecker = Proc(String, Bool)
      alias MonotonicClock = Proc(Time::Instant)
      alias LocalCommandRunner = Proc(LocalCommandRequest, LocalCommandResult)

      def initialize(
        @service : String,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        @output : IO = STDOUT,
        @user : String? = nil,
        @port : Int32? = nil,
        @identity_file : String? = nil,
        @proxy_jump : String? = nil,
        @connect_timeout : Int32? = nil,
        @keepalive : Bool? = nil,
        @keepalive_interval : Int32? = nil,
        local_dependency_checker : DependencyChecker? = nil,
        monotonic_clock : MonotonicClock? = nil,
        local_command_runner : LocalCommandRunner? = nil,
      )
        @local_dependency_checker = local_dependency_checker || ->(command : String) { !Process.find_executable(command).nil? }
        @monotonic_clock = monotonic_clock || -> { Time.instant }
        @local_command_runner = local_command_runner || ->(request : LocalCommandRequest) { execute_local_command(request) }
      end

      def transfer(host : String, image : String) : Nil
        ensure_local_dependency!("rsync")
        ensure_remote_dependency!(host, "skopeo")
        ensure_remote_dependency!(host, "rsync")

        prepare_local_layout!

        print_line(host, "Syncing image #{image} incrementally")
        started_at = @monotonic_clock.call
        # `podman save`, not `skopeo copy containers-storage:`: on macOS podman talks
        # to a VM, so the image lives in the machine's storage while a host-native
        # skopeo reads an empty ~/.local/share/containers/storage and can never find
        # it. podman writes the same OCI layout through the machine, so this is the
        # only export that works on every platform Meridian is driven from. The
        # remote import stays on skopeo -- there podman storage is local.
        run_local!(
          "podman save",
          ["podman", "save", "--format", "oci-dir", "--output", oci_layout_path, image]
        )
        run_remote!(
          host,
          "mkdir",
          ["mkdir", "-p", oci_layout_path]
        )
        rsync_result = run_local!(
          "rsync",
          [
            "rsync",
            "-az",
            "--stats",
            "--delete",
            "-e",
            rsync_shell,
            "#{oci_layout_path}/",
            "#{target_host(host)}:#{oci_layout_path}/",
          ],
          env: {"LC_ALL" => "C"}
        )
        # Wrapped in `podman unshare` because Ubuntu 24.04 ships
        # kernel.apparmor_restrict_unprivileged_userns=1, which denies unshare(2) to
        # binaries without an AppArmor profile. Podman has one and skopeo does not,
        # so a bare `skopeo copy` into rootless containers-storage dies with
        # "Error during unshare(...): Operation not permitted". Running it inside
        # podman's user namespace is the same trick the asset prune already uses.
        run_remote!(
          host,
          "skopeo copy",
          ["podman", "unshare", "skopeo", "copy", "oci:#{oci_layout_path}", "containers-storage:#{image}"]
        )

        elapsed = @monotonic_clock.call - started_at
        transferred = parse_rsync_bytes(rsync_result.stdout) || parse_rsync_bytes(rsync_result.stderr)
        transferred_label = transferred ? format_bytes(transferred) : "unknown bytes"
        print_line(host, "Transferred #{transferred_label} in #{format_duration(elapsed)}")
      rescue ex : DependencyMissing
        raise ex
      rescue ex : SSH::ConnectionError | IO::Error | File::Error
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
          identity_file: @identity_file,
          proxy_jump: @proxy_jump,
          connect_timeout: @connect_timeout,
          keepalive: @keepalive,
          keepalive_interval: @keepalive_interval
        )
        return if result.exit_code.zero?

        raise DependencyMissing.new("Missing remote dependency on #{host}: #{dependency}")
      rescue ex : SSH::ConnectionError
        raise TransferFailed.new(ex.message || "Image transfer to #{host} failed")
      end

      private def prepare_local_layout! : Nil
        FileUtils.rm_rf(oci_layout_path)
        Dir.mkdir_p(oci_layout_path)
      end

      private def run_local!(
        label : String,
        command : Array(String),
        *,
        env : Hash(String, String) = {} of String => String,
      ) : LocalCommandResult
        request = LocalCommandRequest.new(command: command, env: env)
        result = @local_command_runner.call(request)
        return result if result.exit_code.zero?

        raise command_failed(label, result.exit_code, result.stderr, result.stdout)
      end

      private def run_remote!(host : String, label : String, command : Array(String)) : SSH::Result
        result = @ssh_executor.run(
          host,
          command,
          user: @user,
          port: @port,
          identity_file: @identity_file,
          proxy_jump: @proxy_jump,
          connect_timeout: @connect_timeout,
          keepalive: @keepalive,
          keepalive_interval: @keepalive_interval
        )
        return result if result.exit_code.zero?

        raise command_failed(label, result.exit_code, result.stderr, result.stdout)
      rescue ex : SSH::ConnectionError
        raise TransferFailed.new(ex.message || "Image transfer to #{host} failed")
      end

      private def execute_local_command(request : LocalCommandRequest) : LocalCommandResult
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run(
          request.command.first,
          request.command[1..],
          env: request.env,
          output: stdout,
          error: stderr
        )

        LocalCommandResult.new(
          exit_code: status.exit_code,
          stdout: stdout.to_s,
          stderr: stderr.to_s
        )
      rescue ex : IO::Error
        raise TransferFailed.new(ex.message || "Failed to start transfer command")
      end

      private def command_failed(label : String, exit_code : Int32, stderr : String, stdout : String) : TransferFailed
        details = stderr.strip
        details = stdout.strip if details.empty?
        details = "exit code #{exit_code}" if details.empty?
        TransferFailed.new("#{label} failed with exit code #{exit_code}: #{details}")
      end

      # Bytes actually put on the wire, which is the only number that says anything
      # about reuse. GNU rsync labels it "Total bytes sent:", macOS's openrsync
      # "Total sent:". Deliberately no fall back to "Total transferred file size:":
      # that counts whole files considered for transfer, so a redeploy that sent
      # 746 bytes of deltas over a 30 MB layout reports 30 MB -- worse than
      # reporting nothing. Unrecognised output prints "unknown bytes".
      private def parse_rsync_bytes(output : String) : Int64?
        {/Total bytes sent:\s+([0-9,]+)/, /Total sent:\s+([0-9,]+)/}.each do |pattern|
          if match = pattern.match(output)
            return match[1].delete(',').to_i64?
          end
        end

        nil
      end

      private def oci_layout_path : String
        Runtime::Paths.incremental_oci_directory(@service)
      end

      private def target_host(host : String) : String
        return host unless @user

        "#{@user}@#{host}"
      end

      private def rsync_shell : String
        args = ["ssh"] of String

        if port = @port
          args << "-p"
          args << port.to_s
        end

        if identity_file = @identity_file
          args << "-i"
          args << identity_file
        end

        if proxy_jump = @proxy_jump
          args << "-J"
          args << proxy_jump
        end

        if connect_timeout = @connect_timeout
          args << "-o"
          args << "ConnectTimeout=#{connect_timeout}"
        end

        if @keepalive == false
          args << "-o"
          args << "ServerAliveInterval=0"
        elsif @keepalive
          args << "-o"
          args << "ServerAliveInterval=#{@keepalive_interval || 30}"
          args << "-o"
          args << "ServerAliveCountMax=3"
        end

        Process.quote_posix(args)
      end

      private def print_line(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
