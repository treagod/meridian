require "../spec_helper"

def transfer_ssh_ok(stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: 0, stdout: stdout, stderr: stderr)
end

def transfer_ssh_fail(exit_code : Int32 = 1, stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr)
end

def build_test_stream(
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  user : String? = "deploy",
  port : Int32? = nil,
  identity_file : String? = nil,
  local_dependency_checker : Meridian::Transfer::Stream::DependencyChecker = ->(_command : String) { true },
  monotonic_clock : Meridian::Transfer::Stream::MonotonicClock = -> { Time.instant },
  pipeline_runner : Meridian::Transfer::Stream::PipelineRunner = ->(_request : Meridian::Transfer::Stream::PipelineRequest) { Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64) },
)
  Meridian::Transfer::Stream.new(
    Meridian::SSH::Executor.new(runner: runner),
    output: output,
    user: user,
    port: port,
    identity_file: identity_file,
    local_dependency_checker: local_dependency_checker,
    monotonic_clock: monotonic_clock,
    pipeline_runner: pipeline_runner
  )
end

describe "Meridian::Transfer::Stream" do
  describe "#transfer" do
    it "builds a podman save command for the source image" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_ok)
      request = nil.as(Meridian::Transfer::Stream::PipelineRequest?)
      stream = build_test_stream(
        runner: runner,
        pipeline_runner: ->(candidate : Meridian::Transfer::Stream::PipelineRequest) do
          request = candidate
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64)
        end
      )

      stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      captured_request = request.as(Meridian::Transfer::Stream::PipelineRequest)
      captured_request.save_command.should eq(["podman", "save", "registry.example.com/myorg/myapp"])
    end

    it "pipes the image through zstd compression" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_ok)
      request = nil.as(Meridian::Transfer::Stream::PipelineRequest?)
      stream = build_test_stream(
        runner: runner,
        pipeline_runner: ->(candidate : Meridian::Transfer::Stream::PipelineRequest) do
          request = candidate
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64)
        end
      )

      stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      captured_request = request.as(Meridian::Transfer::Stream::PipelineRequest)
      captured_request.compress_command.should eq(["zstd", "--stdout"])
      captured_request.remote_command.should eq("zstd --decompress --stdout | podman load")
    end

    it "targets the correct remote host" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_ok)
      request = nil.as(Meridian::Transfer::Stream::PipelineRequest?)
      stream = build_test_stream(
        runner: runner,
        user: "deployer",
        port: 2222,
        identity_file: "/tmp/id_ed25519",
        pipeline_runner: ->(candidate : Meridian::Transfer::Stream::PipelineRequest) do
          request = candidate
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64)
        end
      )

      stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      captured_request = request.as(Meridian::Transfer::Stream::PipelineRequest)
      captured_request.ssh_args.should eq([
        "-p",
        "2222",
        "-i",
        "/tmp/id_ed25519",
        "deployer@192.168.1.10",
        "zstd --decompress --stdout | podman load",
      ])
    end

    it "raises TransferFailed when the pipeline exits with a non-zero code" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_ok)
      stream = build_test_stream(
        runner: runner,
        pipeline_runner: ->(_candidate : Meridian::Transfer::Stream::PipelineRequest) do
          raise Meridian::Transfer::TransferFailed.new("ssh failed with exit code 1: boom")
        end
      )

      expect_raises(Meridian::Transfer::TransferFailed, /exit code 1/) do
        stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end
    end

    it "raises DependencyMissing when zstd is not installed locally" do
      runner = FakeSSHRunner.new
      pipeline_called = false
      stream = build_test_stream(
        runner: runner,
        local_dependency_checker: ->(_command : String) { false },
        pipeline_runner: ->(_candidate : Meridian::Transfer::Stream::PipelineRequest) do
          pipeline_called = true
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64)
        end
      )

      expect_raises(Meridian::Transfer::DependencyMissing, /Missing local dependency: zstd/) do
        stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      pipeline_called.should be_false
      runner.invocations.should be_empty
    end

    it "raises DependencyMissing when zstd is not installed remotely" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_fail(127, "", "zstd: command not found"))
      pipeline_called = false
      stream = build_test_stream(
        runner: runner,
        pipeline_runner: ->(_candidate : Meridian::Transfer::Stream::PipelineRequest) do
          pipeline_called = true
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64)
        end
      )

      expect_raises(Meridian::Transfer::DependencyMissing, /Missing remote dependency on 192\.168\.1\.10: zstd/) do
        stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")
      end

      pipeline_called.should be_false
    end

    it "prints transferred bytes and elapsed time" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", transfer_ssh_ok)
      output = IO::Memory.new
      ticks = [
        Time::Instant.new(0, 0),
        Time::Instant.new(1, 500_000_000),
      ]
      stream = build_test_stream(
        runner: runner,
        output: output,
        monotonic_clock: -> { ticks.shift? || Time::Instant.new(1, 500_000_000) },
        pipeline_runner: ->(_candidate : Meridian::Transfer::Stream::PipelineRequest) do
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 512_i64)
        end
      )

      stream.transfer("192.168.1.10", "registry.example.com/myorg/myapp")

      output.to_s.should contain("[192.168.1.10] Streaming image registry.example.com/myorg/myapp")
      output.to_s.should contain("[192.168.1.10] Transferred 512 bytes in 1.5s")
    end
  end
end
