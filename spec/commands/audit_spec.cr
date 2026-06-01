require "../spec_helper"

private def build_audit_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Commands::Audit.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Audit" do
  describe "#run" do
    it "prints recent entries for every server and accessory host" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_ok("2026-05-21T09:00:00Z | ops | lock | acquired\n" \
               "2026-05-21T09:05:00Z | ops | deploy | role=web\n")
      )
      output = IO::Memory.new
      command = build_audit_command(runner: runner, output: output)

      command.run(nil, 20).should eq(0)

      printed = output.to_s
      printed.should contain("[192.168.1.10]")
      printed.should contain("ops | deploy | role=web")
      printed.should contain("[192.168.1.20]")
      printed.should contain("(no audit entries)")
    end

    it "limits output to a single host when one is given" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_audit_command(runner: runner, output: output)

      command.run("192.168.1.12", 20).should eq(0)

      output.to_s.should contain("[192.168.1.12]")
      output.to_s.should_not contain("[192.168.1.10]")
    end

    it "raises ArgumentError for a host that is not configured" do
      command = build_audit_command

      expect_raises(ArgumentError, /Unknown host: 10.0.0.1/) do
        command.run("10.0.0.1", 20)
      end
    end

    it "tails the requested number of entries" do
      runner = FakeSSHRunner.new
      command = build_audit_command(runner: runner)

      command.run("192.168.1.10", 5)

      value!(runner.invocations.last.remote_command).should contain("tail -n 5")
    end
  end
end
