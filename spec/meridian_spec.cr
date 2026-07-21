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
      result.output.should contain("check")
      result.output.should contain("logs")
      result.output.should contain("exec")
      result.output.should contain("accessory")
      result.output.should contain("quadlet")
      result.output.should contain("proxy")
      result.output.should contain("Run `meridian COMMAND --help`")
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

        result = run_cli(["deploy", "--config", config_path], orchestrator_factory: orchestrator_factory)

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

        result = run_cli(["deploy", "--config", config_path], orchestrator_factory: orchestrator_factory)

        result.exit_code.should eq(1)
        result.output.should contain("pull failed")
      end
    end

    it "exits non-zero naming a missing files: source before touching any host" do
      with_tempdir do |path|
        missing_path = File.join(path, "nginx.conf")
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, <<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          files:
            - source: #{missing_path}
              destination: /home/deploy/nginx.conf
          YAML

        runner = FakeSSHRunner.new
        result = run_cli(
          ["deploy", "--config", config_path],
          ssh_executor: Meridian::SSH::Executor.new(runner: runner)
        )

        result.exit_code.should eq(1)
        result.output.should contain(missing_path)
        runner.invocations.should be_empty
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

        result = run_cli(["setup", "--config", config_path], proxy_manager_factory: proxy_manager_factory)

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

        result = run_cli(["setup", "--config", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(1)
        result.output.should contain("proxy start failed")
      end
    end

    it "runs the rollback subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      runner.enqueue_results_for_host("192.168.1.10", ssh_fail(1, "", "No such file\n"), ssh_ok("blue\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok)
      runner.enqueue_results_for_host("192.168.1.11", ssh_fail(1, "", "No such file\n"), ssh_ok("green\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok)
      executor = Meridian::SSH::Executor.new(
        runner: runner,
        streaming_runner: FakeSSHStreamingRunner.new
      )

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["rollback", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/.meridian-color"))
        uploads.size.should eq(2)
      end
    end

    it "prints help for the init subcommand" do
      result = run_cli(["init", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian init [options]")
      result.output.should contain("--force")
    end

    it "prints help for the deploy subcommand" do
      result = run_cli(["deploy", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian deploy [options]")
      result.output.should contain("--config PATH")
      result.output.should contain(".meridian/deploy.yml")
    end

    it "rejects the removed --file flag" do
      result = run_cli(["deploy", "--file", "deploy.yml"])

      result.exit_code.should eq(1)
      result.output.should contain("--file")
    end

    it "prints help for the setup subcommand" do
      result = run_cli(["setup", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian setup [options]")
      result.output.should contain("--config PATH")
    end

    it "runs the status subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(
        runner: runner,
        streaming_runner: FakeSSHStreamingRunner.new
      )

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["status", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        result.output.should contain("role")
        result.output.should contain("192.168.1.10")
        result.output.should contain("192.168.1.12")
      end
    end

    it "prints help for the status subcommand" do
      result = run_cli(["status", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian status [options]")
      result.output.should contain("--config PATH")
    end

    it "runs the check subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(
        runner: runner,
        streaming_runner: FakeSSHStreamingRunner.new
      )

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, <<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
          YAML

        runner.enqueue_results(
          ssh_ok,
          ssh_ok("podman version 4.4.1\n"),
          ssh_ok,
          ssh_ok
        )

        result = run_cli(["check", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        result.output.should contain("Check passed")
        remote_commands_for(runner, "192.168.1.10").should contain("podman --version")
      end
    end

    it "prints help for the check subcommand" do
      result = run_cli(["check", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian check [options]")
      result.output.should contain("--config PATH")
    end

    it "runs the logs subcommand on the selected host" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["logs", "--host", "192.168.1.10", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        streaming_runner.invocations.map(&.host).should eq(["192.168.1.10"])
      end
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

        result = run_cli(["proxy", "remove", "--config", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(0)
        fake_manager.should_not be_nil
        fake_manager.try(&.remove_calls).should eq(1)
      end
    end

    it "runs the accessory start subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(
        runner: runner,
        streaming_runner: FakeSSHStreamingRunner.new
      )

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["accessory", "start", "db", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        runner.invocations.compact_map(&.remote_command).should contain("cat > .config/containers/systemd/db.container")
      end
    end

    it "runs the accessory stop subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      executor = Meridian::SSH::Executor.new(
        runner: runner,
        streaming_runner: FakeSSHStreamingRunner.new
      )

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["accessory", "stop", "db", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        runner.invocations.compact_map(&.remote_command).should contain("systemctl --user stop db.service")
      end
    end

    it "runs the accessory logs subcommand with the loaded config" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["accessory", "logs", "db", "--config", config_path], ssh_executor: executor)

        result.exit_code.should eq(0)
        streaming_runner.invocations.map(&.host).should eq(["192.168.1.20"])
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

        result = run_cli(["proxy", "remove", "--config", config_path], proxy_manager_factory: proxy_manager_factory)

        result.exit_code.should eq(1)
        result.output.should contain("proxy stop failed")
      end
    end

    it "exits with a non-zero code for unknown proxy subcommands" do
      result = run_cli(["proxy", "bogus"])

      result.exit_code.should eq(1)
      result.output.should contain("Unknown proxy subcommand: bogus")
    end

    it "prints help for the proxy command" do
      result = run_cli(["proxy", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian proxy SUBCOMMAND [options]")
      result.output.should contain("remove")
    end

    it "prints help for the proxy remove subcommand" do
      result = run_cli(["proxy", "remove", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian proxy remove [options]")
      result.output.should contain("--config PATH")
    end

    it "runs the exec subcommand inside the active role container" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)
        runner.enqueue_results(
          ssh_ok("blue\n"),
          ssh_ok("true\n"),
        )

        result = run_cli(["exec", "web", "--config", config_path, "--", "uptime"], ssh_executor: executor)

        result.exit_code.should eq(0)
        streaming_runner.invocations.last.host.should eq("192.168.1.10")
        streaming_runner.invocations.last.remote_command.should eq("podman exec -i myapp-blue uptime")
      end
    end

    it "propagates the exec exit code" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      streaming_runner.next_result = FakeSSHStreamResult.new(exit_code: 23, stderr: "failed\n")
      executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)
        runner.enqueue_results(
          ssh_ok("blue\n"),
          ssh_ok("true\n"),
        )

        result = run_cli(["exec", "web", "--config", config_path, "--", "false"], ssh_executor: executor)

        result.exit_code.should eq(23)
      end
    end

    it "prints stdout and stderr from exec" do
      runner = FakeSSHRunner.new
      streaming_runner = FakeSSHStreamingRunner.new
      streaming_runner.next_result = FakeSSHStreamResult.new(exit_code: 0, stdout: "hello\n", stderr: "warn\n")
      executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)

      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)
        runner.enqueue_results(
          ssh_ok("blue\n"),
          ssh_ok("true\n"),
        )

        result = run_cli(["exec", "web", "--config", config_path, "--", "uptime"], ssh_executor: executor)

        result.output.should eq("hello\nwarn\n")
      end
    end

    it "exits with a non-zero code when exec is missing a role" do
      result = run_cli(["exec", "--", "uptime"])

      result.exit_code.should eq(1)
      result.output.should contain("Missing required role")
    end

    it "exits with a non-zero code when exec is missing a command" do
      result = run_cli(["exec", "web", "--"])

      result.exit_code.should eq(1)
      result.output.should contain("Missing command after --")
    end

    it "prints help for the exec subcommand" do
      result = run_cli(["exec", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian exec ROLE [options] -- COMMAND [ARGS...]")
      result.output.should contain("--host HOST")
      result.output.should contain("--config PATH")
    end

    it "prints help for the accessory command" do
      result = run_cli(["accessory", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian accessory SUBCOMMAND NAME [options]")
      result.output.should contain("start")
      result.output.should contain("stop")
      result.output.should contain("logs")
    end

    it "prints help for the accessory start subcommand" do
      result = run_cli(["accessory", "start", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian accessory start NAME [options]")
      result.output.should contain("--config PATH")
    end

    it "prints help for the accessory stop subcommand" do
      result = run_cli(["accessory", "stop", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian accessory stop NAME [options]")
      result.output.should contain("--config PATH")
    end

    it "prints help for the accessory logs subcommand" do
      result = run_cli(["accessory", "logs", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian accessory logs NAME [options]")
      result.output.should contain("--config PATH")
    end

    it "exits with a non-zero code for unknown accessory subcommands" do
      result = run_cli(["accessory", "bogus"])

      result.exit_code.should eq(1)
      result.output.should contain("Unknown accessory subcommand: bogus")
    end

    it "exits with a non-zero code when accessory is missing a name" do
      result = run_cli(["accessory", "start"])

      result.exit_code.should eq(1)
      result.output.should contain("Missing accessory name")
    end

    it "writes a quadlet preview when a color, file, and output directory are provided" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        output_dir = File.join(path, "preview")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--color", "green", "--output-dir", output_dir, "--config", config_path])

        result.exit_code.should eq(0)
        result.output.should contain("Wrote Quadlet preview to #{output_dir}")
        File.exists?(File.join(output_dir, "myapp-green.container")).should be_true
        File.exists?(File.join(output_dir, "myapp.network")).should be_true
        File.exists?(File.join(output_dir, "kamal-proxy.container")).should be_true
        File.exists?(File.join(output_dir, "db.container")).should be_true
      end
    end

    it "writes a quadlet preview to the default output directory" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        Dir.cd(path) do
          result = run_cli(["quadlet", "--color", "green", "--config", config_path])

          result.exit_code.should eq(0)
          File.exists?(File.join(path, "quadlet-preview", "myapp-green.container")).should be_true
          File.exists?(File.join(path, "quadlet-preview", "myapp.network")).should be_true
          File.exists?(File.join(path, "quadlet-preview", "db.container")).should be_true
        end
      end
    end

    it "exits with a non-zero code when quadlet is missing a color" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--config", config_path])

        result.exit_code.should eq(1)
        result.output.should contain("Missing required option: --color")
      end
    end

    it "exits with a non-zero code when quadlet is given an invalid color" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        output_dir = File.join(path, "preview")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["quadlet", "--color", "red", "--output-dir", output_dir, "--config", config_path])

        result.exit_code.should eq(1)
        result.output.should contain("Invalid color: red")
      end
    end

    it "prints help for the quadlet subcommand" do
      result = run_cli(["quadlet", "--help"])

      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian quadlet [options]")
      result.output.should contain("--color COLOR")
      result.output.should contain("--output-dir DIR")
    end

    it "exits with a non-zero code for unknown subcommands" do
      result = run_cli(["nonexistent-command"])
      result.exit_code.should eq(1)
    end

    it "prints an error message for unknown subcommands" do
      result = run_cli(["nonexistent-command"])
      result.output.should contain("Unknown command: nonexistent-command")
    end

    it "prints server subcommand help" do
      result = run_cli(["server", "--help"])
      result.exit_code.should eq(0)
      result.output.should contain("bootstrap")
    end

    it "prints server bootstrap help" do
      result = run_cli(["server", "bootstrap", "--help"])
      result.exit_code.should eq(0)
      result.output.should contain("Usage: meridian server bootstrap")
      result.output.should contain("--host HOST")
      result.output.should contain("--deploy-user USER")
    end

    it "exits non-zero when server bootstrap has no --host and multiple hosts are configured" do
      with_tempdir do |path|
        config_path = File.join(path, "deploy.yml")
        File.write(config_path, FULL_CONFIG)

        result = run_cli(["server", "bootstrap", "--config", config_path])
        result.exit_code.should eq(1)
        result.output.should contain("Multiple hosts")
      end
    end

    it "exits non-zero for unknown server subcommand" do
      result = run_cli(["server", "unknown"])
      result.exit_code.should eq(1)
      result.output.should contain("Unknown server subcommand: unknown")
    end

    it "exits non-zero when server subcommand is missing" do
      result = run_cli(["server"])
      result.exit_code.should eq(1)
      result.output.should contain("Missing server subcommand")
    end

    it "includes server in the global help output" do
      result = run_cli(["--help"])
      result.exit_code.should eq(0)
      result.output.should contain("server")
    end
  end
end

describe "Meridian::CLI lock and audit commands" do
  it "reports no lock for `lock status` when the lock host is free" do
    runner = FakeSSHRunner.new
    runner.next_result = Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "")
    executor = Meridian::SSH::Executor.new(runner: runner)

    with_tempdir do |path|
      config_path = File.join(path, "deploy.yml")
      File.write(config_path, MINIMAL_CONFIG)

      result = run_cli(["lock", "status", "--config", config_path], ssh_executor: executor)

      result.exit_code.should eq(0)
      result.output.should contain("No deploy lock held on 192.168.1.10")
    end
  end

  it "acquires a lock with `lock acquire`" do
    runner = FakeSSHRunner.new
    executor = Meridian::SSH::Executor.new(runner: runner)

    with_tempdir do |path|
      config_path = File.join(path, "deploy.yml")
      File.write(config_path, MINIMAL_CONFIG)

      result = run_cli(
        ["lock", "acquire", "--message", "maintenance", "--config", config_path],
        ssh_executor: executor
      )

      result.exit_code.should eq(0)
      result.output.should contain("Acquired deploy lock on 192.168.1.10")
    end
  end

  it "exits non-zero for `lock acquire` when a lock is already held" do
    metadata = Meridian::Runtime::LockMetadata.new(
      actor: "ops@ci",
      acquired_at: "2026-05-20T09:00:00Z",
      message: "release freeze"
    )
    runner = FakeSSHRunner.new
    runner.enqueue_results(
      ssh_ok,
      Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "File exists\n"),
      ssh_ok,
      ssh_ok(metadata.to_json)
    )
    executor = Meridian::SSH::Executor.new(runner: runner)

    with_tempdir do |path|
      config_path = File.join(path, "deploy.yml")
      File.write(config_path, MINIMAL_CONFIG)

      result = run_cli(["lock", "acquire", "--config", config_path], ssh_executor: executor)

      result.exit_code.should eq(1)
      result.output.should contain("held by ops@ci since 2026-05-20T09:00:00Z: release freeze")
    end
  end

  it "releases a lock with `lock release`" do
    metadata = Meridian::Runtime::LockMetadata.new(
      actor: "ops@ci",
      acquired_at: "2026-05-20T09:00:00Z"
    )
    runner = FakeSSHRunner.new
    runner.enqueue_results(ssh_ok, ssh_ok(metadata.to_json), ssh_ok)
    executor = Meridian::SSH::Executor.new(runner: runner)

    with_tempdir do |path|
      config_path = File.join(path, "deploy.yml")
      File.write(config_path, MINIMAL_CONFIG)

      result = run_cli(["lock", "release", "--config", config_path], ssh_executor: executor)

      result.exit_code.should eq(0)
      result.output.should contain("Releasing deploy lock on 192.168.1.10")
    end
  end

  it "prints help for the lock command" do
    result = run_cli(["lock", "--help"])

    result.exit_code.should eq(0)
    result.output.should contain("Usage: meridian lock SUBCOMMAND")
    result.output.should contain("status")
    result.output.should contain("acquire")
    result.output.should contain("release")
  end

  it "prints recent audit entries with `audit`" do
    runner = FakeSSHRunner.new
    runner.enqueue_results_for_host(
      "192.168.1.10",
      ssh_ok("2026-05-21T09:00:00Z | ops | lock | acquired\n" \
             "2026-05-21T09:05:00Z | ops | deploy | role=web\n")
    )
    executor = Meridian::SSH::Executor.new(runner: runner)

    with_tempdir do |path|
      config_path = File.join(path, "deploy.yml")
      File.write(config_path, MINIMAL_CONFIG)

      result = run_cli(
        ["audit", "--host", "192.168.1.10", "--config", config_path],
        ssh_executor: executor
      )

      result.exit_code.should eq(0)
      result.output.should contain("[192.168.1.10]")
      result.output.should contain("ops | deploy | role=web")
    end
  end

  it "prints help for the audit command" do
    result = run_cli(["audit", "--help"])

    result.exit_code.should eq(0)
    result.output.should contain("Usage: meridian audit [options]")
    result.output.should contain("--lines")
  end

  it "lists lock and audit in the global help output" do
    result = run_cli(["--help"])

    result.exit_code.should eq(0)
    result.output.should contain("lock")
    result.output.should contain("audit")
  end
end
