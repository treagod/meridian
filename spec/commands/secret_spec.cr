require "../spec_helper"

def build_secret_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Commands::Secret.new(config, ssh_executor: executor, output: output, error: output)
end

def secret_commands_for(runner : FakeSSHRunner, host : String) : Array(String)
  runner.invocations.compact_map do |invocation|
    next unless invocation.host == host

    invocation.remote_command
  end
end

describe "Meridian::Commands::Secret" do
  describe "#set" do
    it "runs podman secret create on each host in the role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("DATABASE_URL", "postgres://localhost/myapp")

      secret_commands_for(runner, "192.168.1.10").should contain(
        "podman secret create --replace DATABASE_URL -"
      )
      secret_commands_for(runner, "192.168.1.11").should contain(
        "podman secret create --replace DATABASE_URL -"
      )
    end

    it "passes the secret value as stdin input" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("DATABASE_URL", "my-secret-value")

      upload = runner.invocations.find do |inv|
        inv.remote_command == "podman secret create --replace DATABASE_URL -"
      end
      upload.should_not be_nil
      upload.not_nil!.input.should eq("my-secret-value")
    end

    it "targets only the specified role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("SIDEKIQ_CONCURRENCY", "10", "workers")

      secret_commands_for(runner, "192.168.1.12").should contain(
        "podman secret create --replace SIDEKIQ_CONCURRENCY -"
      )
      secret_commands_for(runner, "192.168.1.10").should be_empty
      secret_commands_for(runner, "192.168.1.11").should be_empty
    end

    it "raises UnknownRole when the role does not exist" do
      command = build_secret_command

      expect_raises(Meridian::Config::UnknownRole, /Unknown role: nonexistent/) do
        command.set("KEY", "value", "nonexistent")
      end
    end
  end

  describe "#rm" do
    it "runs podman secret rm on each host in the role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.rm("DATABASE_URL")

      secret_commands_for(runner, "192.168.1.10").should eq(["podman secret rm DATABASE_URL"])
      secret_commands_for(runner, "192.168.1.11").should eq(["podman secret rm DATABASE_URL"])
    end

    it "targets only the specified role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.rm("SIDEKIQ_CONCURRENCY", "workers")

      secret_commands_for(runner, "192.168.1.12").should eq(["podman secret rm SIDEKIQ_CONCURRENCY"])
      secret_commands_for(runner, "192.168.1.10").should be_empty
    end
  end

  describe "#ls" do
    it "runs podman secret ls on each host in the role" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "ID    NAME\nabc   DATABASE_URL\n", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "ID    NAME\nabc   DATABASE_URL\n", stderr: ""),
      )
      command = build_secret_command(runner: runner)

      command.ls

      secret_commands_for(runner, "192.168.1.10").should eq(["podman secret ls"])
      secret_commands_for(runner, "192.168.1.11").should eq(["podman secret ls"])
    end

    it "prints the output from each host" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "ID    NAME\nabc   DATABASE_URL\n", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "ID    NAME\nabc   DATABASE_URL\n", stderr: ""),
      )
      output = IO::Memory.new
      command = build_secret_command(runner: runner, output: output)

      command.ls

      output.to_s.should contain("DATABASE_URL")
    end
  end
end
