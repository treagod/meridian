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

def generated_secret_values(runner : FakeSSHRunner) : Array(String)
  runner.invocations.compact_map do |invocation|
    next unless invocation.remote_command == "podman secret create API_KEY -"

    invocation.input
  end
end

describe "Meridian::Commands::Secret" do
  describe "#gen" do
    it "generates a 32-byte hex secret and stores it on each host by default" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "no such secret\n"),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "no such secret\n")
      )
      command = build_secret_command(runner: runner)

      command.gen("API_KEY")

      generated_secret_values(runner).size.should eq(2)
      generated_secret_values(runner).each do |value|
        value.should match(/\A[0-9a-f]{64}\z/)
      end
      secret_commands_for(runner, "192.168.1.10").should eq([
        "podman secret inspect API_KEY",
        "podman secret rm -i API_KEY",
        "podman secret create API_KEY -",
      ])
      secret_commands_for(runner, "192.168.1.11").should eq([
        "podman secret inspect API_KEY",
        "podman secret rm -i API_KEY",
        "podman secret create API_KEY -",
      ])
    end

    it "supports base64 encoding" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "")
      )
      command = build_secret_command(runner: runner)

      command.gen("API_KEY", length: 6, format: Meridian::Commands::Secret::GeneratedSecretFormat::Base64)

      generated_secret_values(runner).each do |value|
        value.should match(/\A[A-Za-z0-9+\/]{8}\z/)
      end
    end

    it "supports unpadded base64url encoding" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "")
      )
      command = build_secret_command(runner: runner)

      command.gen("API_KEY", length: 5, format: Meridian::Commands::Secret::GeneratedSecretFormat::Base64url)

      generated_secret_values(runner).each do |value|
        value.should match(/\A[A-Za-z0-9_-]{7}\z/)
        value.should_not contain("=")
      end
    end

    it "refuses to overwrite existing secrets by default" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", Meridian::SSH::Result.new(exit_code: 0, stdout: "[]", stderr: ""))
      runner.enqueue_results_for_host("192.168.1.11", Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "no such secret\n"))
      command = build_secret_command(runner: runner)

      expect_raises(Meridian::Commands::SecretExists, /192\.168\.1\.10.*--force/) do
        command.gen("API_KEY")
      end

      remote_commands_for(runner).should eq([
        "podman secret inspect API_KEY",
        "podman secret inspect API_KEY",
      ])
    end

    it "rotates existing secrets when forced" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "[]", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "[]", stderr: "")
      )
      command = build_secret_command(runner: runner)

      command.gen("API_KEY", force: true)

      secret_commands_for(runner, "192.168.1.10").should eq([
        "podman secret inspect API_KEY",
        "podman secret rm -i API_KEY",
        "podman secret create API_KEY -",
      ])
      secret_commands_for(runner, "192.168.1.11").should eq([
        "podman secret inspect API_KEY",
        "podman secret rm -i API_KEY",
        "podman secret create API_KEY -",
      ])
    end

    it "never prints generated values during remote writes" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "")
      )
      output = IO::Memory.new
      command = build_secret_command(runner: runner, output: output)

      command.gen("API_KEY")

      generated_secret_values(runner).each do |value|
        output.to_s.should_not contain(value)
      end
    end
  end

  describe "#set" do
    it "removes then creates the secret on each host in the role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("DATABASE_URL", "postgres://localhost/myapp")

      secret_commands_for(runner, "192.168.1.10").should eq([
        "podman secret rm -i DATABASE_URL",
        "podman secret create DATABASE_URL -",
      ])
      secret_commands_for(runner, "192.168.1.11").should eq([
        "podman secret rm -i DATABASE_URL",
        "podman secret create DATABASE_URL -",
      ])
    end

    it "passes the secret value only to the create command as stdin input" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("DATABASE_URL", "my-secret-value")

      upload = runner.invocations.find! do |inv|
        inv.remote_command == "podman secret create DATABASE_URL -"
      end
      upload.input.should eq("my-secret-value")

      removal = runner.invocations.find! do |inv|
        inv.remote_command == "podman secret rm -i DATABASE_URL"
      end
      removal.input.should be_nil
    end

    it "targets only the specified role" do
      runner = FakeSSHRunner.new
      command = build_secret_command(runner: runner)

      command.set("SIDEKIQ_CONCURRENCY", "10", "workers")

      secret_commands_for(runner, "192.168.1.12").should eq([
        "podman secret rm -i SIDEKIQ_CONCURRENCY",
        "podman secret create SIDEKIQ_CONCURRENCY -",
      ])
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

describe "Meridian::CLI secret gen" do
  it "prints the generated value locally without loading config or contacting hosts" do
    runner = FakeSSHRunner.new
    executor = Meridian::SSH::Executor.new(runner: runner)

    result = run_cli(["secret", "gen", "API_KEY", "--print", "--length", "4", "--format", "base64url"], ssh_executor: executor)

    result.exit_code.should eq(0)
    result.output.chomp.should match(/\A[A-Za-z0-9_-]{6}\z/)
    runner.invocations.should be_empty
  end

  it "rejects --print with --force" do
    result = run_cli(["secret", "gen", "API_KEY", "--print", "--force"])

    result.exit_code.should eq(1)
    result.output.should contain("--print and --force cannot be used together")
  end

  it "rejects invalid lengths" do
    result = run_cli(["secret", "gen", "API_KEY", "--print", "--length", "0"])

    result.exit_code.should eq(1)
    result.output.should contain("Secret length must be greater than 0")
  end

  it "rejects invalid formats" do
    result = run_cli(["secret", "gen", "API_KEY", "--print", "--format", "ascii"])

    result.exit_code.should eq(1)
    result.output.should contain("Unknown secret format: ascii")
  end

  it "is listed in secret help" do
    result = run_cli(["secret", "--help"])

    result.exit_code.should eq(0)
    result.output.should contain("gen")
    result.output.should contain("Generate a random secret")
  end
end
