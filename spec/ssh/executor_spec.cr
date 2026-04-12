require "../spec_helper"

describe "Meridian::SSH::Executor" do
  describe "#run" do
    it "returns exit code 0 for a successful command" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 0, stdout: "ok\n", stderr: "")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = executor.run("1.2.3.4", ["uptime"])

      result.exit_code.should eq(0)
    end

    it "returns the stdout output of the command" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 0, stdout: "load average: 0.42\n", stderr: "")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = executor.run("1.2.3.4", ["uptime"])

      result.stdout.should eq("load average: 0.42\n")
    end

    it "returns a non-zero exit code for a failing command" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 42, stdout: "", stderr: "boom\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = executor.run("1.2.3.4", ["false"])

      result.exit_code.should eq(42)
    end

    it "captures stderr separately from stdout" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 1, stdout: "partial\n", stderr: "failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = executor.run("1.2.3.4", ["false"])

      result.stdout.should eq("partial\n")
      result.stderr.should eq("failed\n")
    end

    it "raises ConnectionError when the host is unreachable" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 255, stdout: "", stderr: "ssh: connect failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      expect_raises(Meridian::SSH::ConnectionError, /1\.2\.3\.4/) do
        executor.run("1.2.3.4", ["uptime"])
      end
    end

    it "respects a custom SSH port" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["uptime"],
        user: "deploy",
        port: 2222,
        identity_file: "/tmp/id_ed25519"
      )

      invocation = runner.invocations.last
      invocation.command.should eq("ssh")
      invocation.args.should eq(["-p", "2222", "-i", "/tmp/id_ed25519", "deploy@1.2.3.4", "uptime"])
    end

    it "adds proxy jump and connect timeout options" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["uptime"],
        proxy_jump: "bastion.example.com",
        connect_timeout: 15
      )

      invocation = runner.invocations.last
      invocation.args.should eq([
        "-J",
        "bastion.example.com",
        "-o",
        "ConnectTimeout=15",
        "1.2.3.4",
        "uptime",
      ])
    end

    it "adds keepalive options when enabled" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["uptime"],
        keepalive: true,
        keepalive_interval: 45
      )

      invocation = runner.invocations.last
      invocation.args.should eq([
        "-o",
        "ServerAliveInterval=45",
        "-o",
        "ServerAliveCountMax=3",
        "1.2.3.4",
        "uptime",
      ])
    end

    it "disables keepalive when configured" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["uptime"],
        keepalive: false
      )

      invocation = runner.invocations.last
      invocation.args.should eq([
        "-o",
        "ServerAliveInterval=0",
        "1.2.3.4",
        "uptime",
      ])
    end

    it "orders SSH options before the target host consistently" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["uptime"],
        user: "deploy",
        port: 2222,
        identity_file: "/tmp/id_ed25519",
        proxy_jump: "bastion.example.com",
        connect_timeout: 12,
        keepalive: true,
        keepalive_interval: 60
      )

      invocation = runner.invocations.last
      invocation.args.should eq([
        "-p",
        "2222",
        "-i",
        "/tmp/id_ed25519",
        "-J",
        "bastion.example.com",
        "-o",
        "ConnectTimeout=12",
        "-o",
        "ServerAliveInterval=60",
        "-o",
        "ServerAliveCountMax=3",
        "deploy@1.2.3.4",
        "uptime",
      ])
    end

    it "passes environment variables to the remote command" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["bin/app", "--flag", "hello world"],
        env: {
          "RAILS_ENV"       => "production",
          "SECRET_KEY_BASE" => "abc 123",
        }
      )

      invocation = runner.invocations.last
      invocation.args.last.should eq("RAILS_ENV=production SECRET_KEY_BASE='abc 123' bin/app --flag 'hello world'")
    end

    it "quotes shell-sensitive values with the stdlib POSIX quoting" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.run(
        "1.2.3.4",
        ["echo", "it's loud"],
        env: {"MESSAGE" => "hi there's"},
      )

      invocation = runner.invocations.last
      invocation.args.last.should eq(%(MESSAGE='hi there'"'"'s' echo 'it'"'"'s loud'))
    end
  end

  describe "#run!" do
    it "raises CommandFailed when the exit code is non-zero" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      expect_raises(Meridian::SSH::CommandFailed, /exit code 1/) do
        executor.run!("1.2.3.4", ["false"])
      end
    end

    it "does not raise when the command succeeds" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 0, stdout: "ok\n", stderr: "")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = executor.run!("1.2.3.4", ["uptime"])

      result.stdout.should eq("ok\n")
    end
  end

  describe "#upload" do
    it "writes content to a file on the remote host" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      executor.upload("1.2.3.4", "/opt/meridian/config.env", "TOKEN=secret\n")

      invocation = runner.invocations.last
      invocation.command.should eq("ssh")
      invocation.args.should eq(["1.2.3.4", "cat > /opt/meridian/config.env"])
      invocation.input.should eq("TOKEN=secret\n")
    end

    it "raises an error when the remote path is not writable" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "permission denied\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      expect_raises(Meridian::SSH::CommandFailed, /config\.env/) do
        executor.upload("1.2.3.4", "/opt/meridian/config.env", "TOKEN=secret\n")
      end
    end

    it "raises ConnectionError when the host is unreachable" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 255, stdout: "", stderr: "connect failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      expect_raises(Meridian::SSH::ConnectionError, /1\.2\.3\.4/) do
        executor.upload("1.2.3.4", "/opt/meridian/config.env", "TOKEN=secret\n")
      end
    end
  end
end
