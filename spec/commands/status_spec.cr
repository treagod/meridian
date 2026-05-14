require "../spec_helper"

def build_status_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(
    runner: runner,
    streaming_runner: FakeSSHStreamingRunner.new
  )
  Meridian::Commands::Status.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Status" do
  describe "#run" do
    it "queries systemctl status on all web hosts" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_status_command(runner: runner, output: output)

      command.run

      remote_commands_for(runner, "192.168.1.10").should eq([
        "systemctl --user status myapp-blue.service --no-pager --lines 0",
        "systemctl --user status myapp-green.service --no-pager --lines 0",
      ])
      remote_commands_for(runner, "192.168.1.11").should eq([
        "systemctl --user status myapp-blue.service --no-pager --lines 0",
        "systemctl --user status myapp-green.service --no-pager --lines 0",
      ])
    end

    it "queries all roles, not only web" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_status_command(runner: runner, output: output)

      command.run

      remote_commands_for(runner, "192.168.1.12").should eq([
        "systemctl --user status myapp-blue.service --no-pager --lines 0",
        "systemctl --user status myapp-green.service --no-pager --lines 0",
      ])
      output.to_s.should contain("workers")
      output.to_s.should contain("192.168.1.12")
    end

    it "scopes output to the supplied targets" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_status_command(runner: runner, output: output)
      targets = [Meridian::CLI::TargetSelector::Target.new(role: "workers", host: "192.168.1.12")]

      command.run(targets)

      hosts = runner.invocations.map(&.host)
      hosts.uniq!
      hosts.should eq(["192.168.1.12"])
      output.to_s.should contain("workers")
      output.to_s.should_not contain("192.168.1.10")
      output.to_s.should_not contain("192.168.1.11")
    end

    it "summarizes active and inactive units" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_status_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
        YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok("Active: active (running)\n"),
        ssh_fail(3, "Active: inactive (dead)\n"),
      )

      command.run

      output.to_s.should contain("active")
      output.to_s.should contain("inactive")
    end
  end
end
