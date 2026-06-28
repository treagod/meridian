require "../spec_helper"

def build_role_exec_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  streaming_runner : FakeSSHStreamingRunner = FakeSSHStreamingRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)
  Meridian::Commands::Exec.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Exec" do
  describe "#run" do
    it "runs the given command inside the running container via podman exec" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_role_exec_command(runner: runner, streaming_runner: streaming_runner)
      runner.enqueue_results(
        ssh_ok("blue\n"),
        ssh_ok("true\n"),
      )

      exit_code = command.run("web", ["env"])

      exit_code.should eq(0)
      streaming_invocation = streaming_runner.invocations.last
      streaming_invocation.host.should eq("192.168.1.10")
      streaming_invocation.remote_command.should eq("podman exec -i myapp-blue env")
    end

    it "defaults to the first host for multi-host roles" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_role_exec_command(runner: runner, streaming_runner: streaming_runner)
      runner.enqueue_results(
        ssh_ok("blue\n"),
        ssh_ok("true\n"),
      )

      command.run("web", ["sh"])

      streaming_runner.invocations.last.host.should eq("192.168.1.10")
    end

    it "honors explicit host selection" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_role_exec_command(runner: runner, streaming_runner: streaming_runner)
      runner.enqueue_results_for_host("192.168.1.11", ssh_ok("green\n"), ssh_ok("true\n"))

      command.run("web", ["env"], "192.168.1.11")

      streaming_runner.invocations.last.host.should eq("192.168.1.11")
      streaming_runner.invocations.last.remote_command.should eq("podman exec -i myapp-green env")
    end

    it "executes directly in the role-named container for a non-proxied role" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_role_exec_command(streaming_runner: streaming_runner)

      command.run("workers", ["env"])

      invocation = streaming_runner.invocations.last
      invocation.host.should eq("192.168.1.12")
      invocation.remote_command.should eq("podman exec -i myapp-workers env")
    end

    it "rejects unmanaged roles whose container names Meridian does not own" do
      command = build_role_exec_command(content: <<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          legacy:
            hosts:
              - 192.168.1.10
            managed: false
            units:
              - legacy-app.service
        YAML

      expect_raises(ArgumentError, /exec is not supported for unmanaged role: legacy/) do
        command.run("legacy", ["env"])
      end
    end

    it "raises an error when the role does not exist" do
      command = build_role_exec_command

      expect_raises(Meridian::Config::UnknownRole, /Unknown role: missing/) do
        command.run("missing", ["env"])
      end
    end

    it "raises when the active color is ambiguous" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_role_exec_command(runner: runner, streaming_runner: streaming_runner)
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "No such file\n"),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "No such file\n"),
        ssh_ok("active\n"),
        ssh_ok("active\n"),
      )

      expect_raises(ArgumentError, /both colors are active/) do
        command.run("web", ["env"])
      end
    end
  end
end
