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
      result.output.should contain("init")
      result.output.should contain("deploy")
      result.output.should contain("setup")
      result.output.should contain("rollback")
      result.output.should contain("status")
      result.output.should contain("logs")
      result.output.should contain("exec")
      result.output.should contain("quadlet")
      result.output.should contain("proxy")
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
    it "runs the deploy subcommand with the loaded config" do
      fake_orchestrator = nil.as(FakeDeployOrchestrator?)
      captured_service = nil.as(String?)
      orchestrator_factory = Meridian::CLI::OrchestratorFactory.new do |config, _ssh_executor, output|
        captured_service = config.service
        orchestrator = FakeDeployOrchestrator.new(config, output: output)
        fake_orchestrator = orchestrator
        orchestrator.as(Meridian::Deploy::Orchestrator)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["deploy", "--file", config_path], orchestrator_factory: orchestrator_factory)

        result.exit_code.should eq(0)
        captured_service.should eq("myapp")
        fake_orchestrator.should_not be_nil
        fake_orchestrator.try(&.deploy_calls).should eq(1)
      end
    end

    it "prints a deploy error and exits non-zero when deployment fails" do
      orchestrator_factory = Meridian::CLI::OrchestratorFactory.new do |config, _ssh_executor, output|
        FakeDeployOrchestrator.new(
          config,
          deploy_error: Meridian::Deploy::DeployFailed.new("pull failed"),
          output: output
        ).as(Meridian::Deploy::Orchestrator)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["deploy", "--file", config_path], orchestrator_factory: orchestrator_factory)

        result.exit_code.should eq(1)
        result.output.should contain("pull failed")
      end
    end

    it "runs the setup subcommand with the loaded config" do
      fake_manager = nil.as(FakeProxyManager?)
      captured_service = nil.as(String?)
      proxy_manager_factory = Meridian::CLI::ProxyManagerFactory.new do |config, _ssh_executor, output|
        captured_service = config.service
        manager = FakeProxyManager.new(config, output: output)
        fake_manager = manager
        manager.as(Meridian::Proxy::Manager)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["setup", "--file", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(0)
        captured_service.should eq("myapp")
        fake_manager.should_not be_nil
        fake_manager.try(&.setup_calls).should eq(1)
      end
    end

    it "prints a setup error and exits non-zero when proxy setup fails" do
      proxy_manager_factory = Meridian::CLI::ProxyManagerFactory.new do |config, _ssh_executor, output|
        FakeProxyManager.new(
          config,
          setup_error: Meridian::Proxy::SetupFailed.new("proxy start failed"),
          output: output
        ).as(Meridian::Proxy::Manager)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["setup", "--file", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(1)
        result.output.should contain("proxy start failed")
      end
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

    it "runs the proxy remove subcommand with the loaded config" do
      fake_manager = nil.as(FakeProxyManager?)
      proxy_manager_factory = Meridian::CLI::ProxyManagerFactory.new do |config, _ssh_executor, output|
        manager = FakeProxyManager.new(config, output: output)
        fake_manager = manager
        manager.as(Meridian::Proxy::Manager)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["proxy", "remove", "--file", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(0)
        fake_manager.should_not be_nil
        fake_manager.try(&.remove_calls).should eq(1)
      end
    end

    it "prints a proxy remove error and exits non-zero when removal fails" do
      proxy_manager_factory = Meridian::CLI::ProxyManagerFactory.new do |config, _ssh_executor, output|
        FakeProxyManager.new(
          config,
          remove_error: Meridian::Proxy::RemoveFailed.new("proxy stop failed"),
          output: output
        ).as(Meridian::Proxy::Manager)
      end

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["proxy", "remove", "--file", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(1)
        result.output.should contain("proxy stop failed")
      end
    end

    it "exits with a non-zero code for unknown proxy subcommands" do
      result = run_cli(["proxy", "bogus"])

      result.exit_code.should eq(1)
      result.output.should contain("Unknown proxy subcommand: bogus")
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

    it "writes a quadlet preview when a color, file, and output directory are provided" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        output_dir = File.join(path, "preview")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--color", "green", "--output-dir", output_dir, "--file", config_path])

        result.exit_code.should eq(0)
        result.output.should contain("Wrote Quadlet preview to #{output_dir}")
        File.exists?(File.join(output_dir, "myapp-green.container")).should be_true
        File.exists?(File.join(output_dir, "myapp.network")).should be_true
        File.exists?(File.join(output_dir, "kamal-proxy.container")).should be_true
      end
    end

    it "writes a quadlet preview to the default output directory" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        Dir.cd(path) do
          result = run_cli(["quadlet", "--color", "green", "--file", config_path])

          result.exit_code.should eq(0)
          File.exists?(File.join(path, "quadlet-preview", "myapp-green.container")).should be_true
          File.exists?(File.join(path, "quadlet-preview", "myapp.network")).should be_true
        end
      end
    end

    it "exits with a non-zero code when quadlet is missing a color" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--file", config_path])

        result.exit_code.should eq(1)
        result.output.should contain("Missing required option: --color")
      end
    end

    it "exits with a non-zero code when quadlet is given an invalid color" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        output_dir = File.join(path, "preview")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--color", "red", "--output-dir", output_dir, "--file", config_path])

        result.exit_code.should eq(1)
        result.output.should contain("Invalid color: red")
      end
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
