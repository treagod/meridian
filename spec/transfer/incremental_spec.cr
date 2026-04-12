require "../spec_helper"

def incremental_ssh_ok(stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: 0, stdout: stdout, stderr: stderr)
end

def incremental_ssh_fail(exit_code : Int32 = 1, stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr)
end

def build_test_incremental(
  service : String = "myapp",
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  user : String? = "deploy",
  port : Int32? = nil,
  identity_file : String? = nil,
  proxy_jump : String? = nil,
  connect_timeout : Int32? = nil,
  keepalive : Bool? = nil,
  keepalive_interval : Int32? = nil,
  local_dependency_checker : Meridian::Transfer::Incremental::DependencyChecker = ->(_command : String) { true },
  monotonic_clock : Meridian::Transfer::Incremental::MonotonicClock = -> { Time.instant },
  local_command_runner : Meridian::Transfer::Incremental::LocalCommandRunner = ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) { Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: "") },
)
  Meridian::Transfer::Incremental.new(
    service,
    Meridian::SSH::Executor.new(runner: runner),
    output: output,
    user: user,
    port: port,
    identity_file: identity_file,
    proxy_jump: proxy_jump,
    connect_timeout: connect_timeout,
    keepalive: keepalive,
    keepalive_interval: keepalive_interval,
    local_dependency_checker: local_dependency_checker,
    monotonic_clock: monotonic_clock,
    local_command_runner: local_command_runner
  )
end

describe "Meridian::Transfer::Incremental" do
  layout_path = "/tmp/meridian-oci/myapp"

  before_each do
    FileUtils.rm_rf(layout_path)
  end

  after_each do
    FileUtils.rm_rf(layout_path)
  end

  describe "#transfer" do
    it "exports the image to an OCI layout directory using skopeo" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      requests.first.command.should eq([
        "skopeo",
        "copy",
        "containers-storage:registry.example.com/myorg/myapp",
        "oci:/tmp/meridian-oci/myapp",
      ])
    end

    it "rsyncs the OCI directory to the remote host" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(
            exit_code: 0,
            stdout: "Total bytes sent: 512\n",
            stderr: ""
          )
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      rsync_request = requests[1]
      rsync_request.command.last.should eq("deploy@192.168.1.10:/tmp/meridian-oci/myapp/")
      rsync_request.command[-2].should eq("/tmp/meridian-oci/myapp/")
      rsync_request.env.should eq({"LC_ALL" => "C"})
    end

    it "uses rsync with archive, compress, stats, delete, and SSH options" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        user: "deployer",
        port: 2222,
        identity_file: "/tmp/id_ed25519",
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(
            exit_code: 0,
            stdout: "Total bytes sent: 512\n",
            stderr: ""
          )
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      rsync_request = requests[1]
      rsync_request.command.should contain("-az")
      rsync_request.command.should contain("--stats")
      rsync_request.command.should contain("--delete")
      rsync_request.command.should contain("deployer@192.168.1.10:/tmp/meridian-oci/myapp/")
      rsync_shell = rsync_request.command[rsync_request.command.index("-e").not_nil! + 1]
      rsync_shell.should eq("ssh -p 2222 -i /tmp/id_ed25519")
    end

    it "threads proxy jump, timeout, and keepalive into the rsync ssh shell" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        proxy_jump: "bastion.example.com",
        connect_timeout: 10,
        keepalive: true,
        keepalive_interval: 30,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(
            exit_code: 0,
            stdout: "Total bytes sent: 512\n",
            stderr: ""
          )
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      rsync_request = requests[1]
      rsync_shell = rsync_request.command[rsync_request.command.index("-e").not_nil! + 1]
      rsync_shell.should eq("ssh -J bastion.example.com -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3")
    end

    it "imports the OCI directory into Podman storage on the remote host via skopeo" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      incremental = build_test_incremental(runner: runner)

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should contain("skopeo copy oci:/tmp/meridian-oci/myapp containers-storage:registry.example.com/myorg/myapp")
    end

    it "raises DependencyMissing when skopeo is not installed locally" do
      runner = FakeSSHRunner.new
      local_commands = 0
      incremental = build_test_incremental(
        runner: runner,
        local_dependency_checker: ->(command : String) { command != "skopeo" },
        local_command_runner: ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          local_commands += 1
          Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      )

      expect_raises(Meridian::Transfer::DependencyMissing, /Missing local dependency: skopeo/) do
        incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      local_commands.should eq(0)
      runner.invocations.should be_empty
    end

    it "raises DependencyMissing when rsync is not installed locally" do
      runner = FakeSSHRunner.new
      local_commands = 0
      incremental = build_test_incremental(
        runner: runner,
        local_dependency_checker: ->(command : String) { command != "rsync" },
        local_command_runner: ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          local_commands += 1
          Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      )

      expect_raises(Meridian::Transfer::DependencyMissing, /Missing local dependency: rsync/) do
        incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      local_commands.should eq(0)
      runner.invocations.should be_empty
    end

    it "raises DependencyMissing when rsync is not installed remotely" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_fail(127, "", "rsync: command not found"))
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      )

      expect_raises(Meridian::Transfer::DependencyMissing, /Missing remote dependency on 192\.168\.1\.10: rsync/) do
        incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      requests.should be_empty
    end

    it "raises TransferFailed when rsync exits with a non-zero code" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      results = [
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 23, stdout: "", stderr: "broken pipe"),
      ]
      incremental = build_test_incremental(
        runner: runner,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          results.shift? || raise "Unexpected local command"
        end
      )

      expect_raises(Meridian::Transfer::TransferFailed, /rsync failed with exit code 23: broken pipe/) do
        incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      requests.map(&.command.first).should eq(["skopeo", "rsync"])
      remote_commands_for(runner, "192.168.1.10").should eq([
        "sh -lc 'command -v skopeo >/dev/null'",
        "sh -lc 'command -v rsync >/dev/null'",
        "mkdir -p /tmp/meridian-oci/myapp",
      ])
    end

    it "runs the skopeo export before the rsync" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      requests = [] of Meridian::Transfer::Incremental::LocalCommandRequest
      incremental = build_test_incremental(
        runner: runner,
        local_command_runner: ->(request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          requests << request
          Meridian::Transfer::Incremental::LocalCommandResult.new(
            exit_code: 0,
            stdout: "Total bytes sent: 256\n",
            stderr: ""
          )
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      requests.map(&.command.first).should eq(["skopeo", "rsync"])
    end

    it "prints transferred bytes and elapsed time from rsync stats" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      output = IO::Memory.new
      ticks = [
        Time::Instant.new(0, 0),
        Time::Instant.new(1, 500_000_000),
      ]
      results = [
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::Transfer::Incremental::LocalCommandResult.new(
          exit_code: 0,
          stdout: "Total bytes sent: 1,024\n",
          stderr: ""
        ),
      ]
      incremental = build_test_incremental(
        runner: runner,
        output: output,
        monotonic_clock: -> { ticks.shift? || Time::Instant.new(1, 500_000_000) },
        local_command_runner: ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          results.shift? || raise "Unexpected local command"
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      output.to_s.should contain("[192.168.1.10] Syncing image registry.example.com/myorg/myapp incrementally")
      output.to_s.should contain("[192.168.1.10] Transferred 1024 bytes in 1.5s")
    end

    it "falls back to total transferred file size when total bytes sent is unavailable" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      output = IO::Memory.new
      results = [
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::Transfer::Incremental::LocalCommandResult.new(
          exit_code: 0,
          stdout: "Total transferred file size: 2048\n",
          stderr: ""
        ),
      ]
      incremental = build_test_incremental(
        runner: runner,
        output: output,
        local_command_runner: ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          results.shift? || raise "Unexpected local command"
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      output.to_s.should contain("[192.168.1.10] Transferred 2048 bytes")
    end

    it "prints unknown bytes when rsync stats do not include a byte total" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok, incremental_ssh_ok)
      output = IO::Memory.new
      results = [
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::Transfer::Incremental::LocalCommandResult.new(exit_code: 0, stdout: "done\n", stderr: ""),
      ]
      incremental = build_test_incremental(
        runner: runner,
        output: output,
        local_command_runner: ->(_request : Meridian::Transfer::Incremental::LocalCommandRequest) do
          results.shift? || raise "Unexpected local command"
        end
      )

      incremental.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      output.to_s.should contain("[192.168.1.10] Transferred unknown bytes")
    end
  end
end
