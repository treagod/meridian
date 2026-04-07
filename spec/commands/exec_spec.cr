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
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("active\n"),
        ssh_ok("active\n"),
      )

      expect_raises(ArgumentError, /both colors are active/) do
        command.run("web", ["env"])
      end
    end
  end
end
