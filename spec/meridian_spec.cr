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

    it "prints 'Not yet implemented' for the exec subcommand" do
      result = run_cli(["exec"])
      result.output.should contain("Not yet implemented")
      result.exit_code.should eq(0)
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
