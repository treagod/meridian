require "./spec_helper"

describe "Meridian::CLI" do
  describe "global flags" do
    it "exits with code 0 when --help is passed" do
      result = run_cli(["--help"])
      result.exit_code.should eq(0)
    end

    it "prints usage information when --help is passed" do
      result = run_cli(["--help"])
      result.output.should contain("Usage:")
      result.output.should contain("deploy")
      result.output.should contain("setup")
      result.output.should contain("rollback")
      result.output.should contain("status")
      result.output.should contain("logs")
      result.output.should contain("exec")
    end

    it "prints the version string when --version is passed" do
      result = run_cli(["--version"])
      result.output.should match(/\d+\.\d+\.\d+/)
    end

    it "exits with code 0 when --version is passed" do
      result = run_cli(["--version"])
      result.exit_code.should eq(0)
    end

    it "prints usage information when no arguments are passed" do
      result = run_cli([] of String)
      result.exit_code.should eq(0)
      result.output.should contain("Usage:")
    end

    it "exits with a non-zero code for invalid options" do
      result = run_cli(["--bogus"])
      result.exit_code.should eq(1)
    end
  end

  describe "subcommands" do
    it "prints 'Not yet implemented' for the deploy subcommand" do
      result = run_cli(["deploy"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
    end

    it "prints 'Not yet implemented' for the setup subcommand" do
      result = run_cli(["setup"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
    end

    it "prints 'Not yet implemented' for the rollback subcommand" do
      result = run_cli(["rollback"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
    end

    it "prints 'Not yet implemented' for the status subcommand" do
      result = run_cli(["status"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
    end

    it "prints 'Not yet implemented' for the logs subcommand" do
      result = run_cli(["logs"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
    end

    it "runs the exec subcommand over SSH when a host and command are provided" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = run_cli(["exec", "--host", "1.2.3.4", "--", "uptime"], ssh_executor: executor)

      invocation = runner.invocations.last
      invocation.command.should eq("ssh")
      invocation.args.should eq(["1.2.3.4", "uptime"])
      result.exit_code.should eq(0)
    end

    it "propagates the exec exit code" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 23, stdout: "", stderr: "failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = run_cli(["exec", "--host", "1.2.3.4", "--", "false"], ssh_executor: executor)

      result.exit_code.should eq(23)
    end

    it "prints stdout and stderr from exec" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 0, stdout: "hello\n", stderr: "warn\n")
      executor = Meridian::SSH::Executor.new(runner: runner)

      result = run_cli(["exec", "--host", "1.2.3.4", "--", "uptime"], ssh_executor: executor)

      result.output.should eq("hello\nwarn\n")
    end

    it "exits with a non-zero code when exec is missing a host" do
      result = run_cli(["exec", "--", "uptime"])

      result.exit_code.should eq(1)
      result.output.should contain("Missing required option: --host")
    end

    it "exits with a non-zero code when exec is missing a command" do
      result = run_cli(["exec", "--host", "1.2.3.4", "--"])

      result.exit_code.should eq(1)
      result.output.should contain("Missing command after --")
    end

    it "exits with a non-zero code for unknown subcommands" do
      result = run_cli(["nonexistent-command"])
      result.exit_code.should eq(1)
    end

    it "prints an error message for unknown subcommands" do
      result = run_cli(["nonexistent-command"])
      result.output.should contain("Unknown command: nonexistent-command")
    end
  end
end
