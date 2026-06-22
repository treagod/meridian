require "../spec_helper"

def build_run_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  streaming_runner : FakeSSHStreamingRunner = FakeSSHStreamingRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)
  Meridian::Commands::Run.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Run" do
  describe "#run" do
    it "runs podman run --rm with the service image" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["bin/rails", "db:migrate"])

      invocation = streaming_runner.invocations.last
      invocation.host.should eq("192.168.1.10")
      value!(invocation.remote_command).should contain("podman run --rm")
      value!(invocation.remote_command).should contain("registry.example.com/myorg/myapp")
      value!(invocation.remote_command).should contain("bin/rails db:migrate")
    end

    it "attaches the service network" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["printenv"])

      invocation = streaming_runner.invocations.last
      value!(invocation.remote_command).should contain("--network myapp")
    end

    it "fails before streaming when setup has not created the service network" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_fail(1))
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(runner: runner, streaming_runner: streaming_runner)

      expect_raises(ArgumentError, /Run `meridian setup` before `meridian run`/) do
        command.run("web", ["printenv"])
      end

      remote_commands_for(runner, "192.168.1.10").should eq(["podman network exists myapp"])
      streaming_runner.invocations.should be_empty
    end

    it "passes env.clear variables as --env flags" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["printenv"])

      invocation = streaming_runner.invocations.last
      value!(invocation.remote_command).should contain("--env RAILS_ENV=production")
      value!(invocation.remote_command).should contain("--env DATABASE_HOST=db.internal")
    end

    it "passes env.secret names as --secret flags" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["printenv"])

      invocation = streaming_runner.invocations.last
      value!(invocation.remote_command).should contain("--secret SECRET_KEY_BASE,type=env,target=SECRET_KEY_BASE")
      value!(invocation.remote_command).should contain("--secret DATABASE_URL,type=env,target=DATABASE_URL")
    end

    it "defaults to the first configured host for the role" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["true"])

      streaming_runner.invocations.last.host.should eq("192.168.1.10")
    end

    it "honors explicit host selection" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(streaming_runner: streaming_runner)

      command.run("web", ["true"], "192.168.1.11")

      streaming_runner.invocations.last.host.should eq("192.168.1.11")
    end

    it "propagates a non-zero exit code" do
      streaming_runner = FakeSSHStreamingRunner.new
      streaming_runner.enqueue_results(FakeSSHStreamResult.new(exit_code: 1))
      command = build_run_command(streaming_runner: streaming_runner)

      exit_code = command.run("web", ["false"])

      exit_code.should eq(1)
    end

    it "raises when the role does not exist" do
      command = build_run_command

      expect_raises(Meridian::Config::UnknownRole, /Unknown role: missing/) do
        command.run("missing", ["true"])
      end
    end

    it "raises when the specified host is not in the role" do
      command = build_run_command

      expect_raises(ArgumentError, /not configured for role/) do
        command.run("web", ["true"], "999.999.999.999")
      end
    end

    it "works without env config" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_run_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 192.168.1.10
          YAML
        streaming_runner: streaming_runner
      )

      command.run("web", ["printenv"])

      invocation = streaming_runner.invocations.last
      value!(invocation.remote_command).should_not contain("--env")
      value!(invocation.remote_command).should_not contain("--secret")
    end
  end
end
