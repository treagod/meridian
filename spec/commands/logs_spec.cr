require "../spec_helper"

def build_logs_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  streaming_runner : FakeSSHStreamingRunner = FakeSSHStreamingRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)
  Meridian::Commands::Logs.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Logs" do
  describe "#run" do
    it "runs journalctl on the specified host" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_logs_command(streaming_runner: streaming_runner)

      exit_code = command.run("192.168.1.10")

      exit_code.should eq(0)
      streaming_runner.invocations.map(&.host).should eq(["192.168.1.10"])
    end

    it "passes the follow flag to journalctl" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_logs_command(streaming_runner: streaming_runner)

      command.run("192.168.1.10")

      invocation = streaming_runner.invocations.last
      remote_command = invocation.remote_command.not_nil!
      remote_command.should contain("journalctl --user")
      remote_command.should contain("-f")
      remote_command.should contain("--no-pager")
    end

    it "filters journalctl output by the service name" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_logs_command(streaming_runner: streaming_runner)

      command.run("192.168.1.10")

      invocation = streaming_runner.invocations.last
      remote_command = invocation.remote_command.not_nil!
      remote_command.should contain("-u myapp-blue.service")
      remote_command.should contain("-u myapp-green.service")
    end

    it "prefixes multiplexed output by host when streaming all hosts" do
      streaming_runner = FakeSSHStreamingRunner.new
      output = IO::Memory.new
      command = build_logs_command(streaming_runner: streaming_runner, output: output)
      streaming_runner.enqueue_results_for_host("192.168.1.10", FakeSSHStreamResult.new(exit_code: 0, stdout: "blue\n"))
      streaming_runner.enqueue_results_for_host("192.168.1.11", FakeSSHStreamResult.new(exit_code: 0, stdout: "green\n"))
      streaming_runner.enqueue_results_for_host("192.168.1.12", FakeSSHStreamResult.new(exit_code: 0, stdout: "worker\n"))

      exit_code = command.run

      exit_code.should eq(0)
      output.to_s.should contain("[192.168.1.10] blue")
      output.to_s.should contain("[192.168.1.11] green")
      output.to_s.should contain("[192.168.1.12] worker")
    end
  end
end
