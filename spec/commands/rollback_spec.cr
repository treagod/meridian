require "../spec_helper"

def rollback_config : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
          - 192.168.1.11
        proxy:
          host: myapp.example.com
          ssl: true
          app_port: 3000
          healthcheck:
            path: /health
            interval: 2
            timeout: 5
            retries: 10

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest
  YAML
end

def single_host_rollback_config : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
        proxy:
          host: myapp.example.com
          ssl: true
          app_port: 3000
          healthcheck:
            path: /health
            interval: 2
            timeout: 5
            retries: 10

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest
  YAML
end

def build_rollback_command(
  content : String = rollback_config,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(
    runner: runner,
    streaming_runner: FakeSSHStreamingRunner.new
  )
  Meridian::Commands::Rollback.new(config, ssh_executor: executor, output: output, error: output)
end

describe "Meridian::Commands::Rollback" do
  describe "#run" do
    it "reads the active colour from the service-scoped state path on each host when no release state is present" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(runner: runner)
      runner.enqueue_results_for_host("192.168.1.10", ssh_fail(1, "", "No such file\n"), ssh_ok("blue\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok)
      runner.enqueue_results_for_host("192.168.1.11", ssh_fail(1, "", "No such file\n"), ssh_ok("green\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok)

      command.run

      reads = runner.invocations.select(&.remote_command.==("cat .local/state/meridian/services/myapp/active-color"))
      reads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "switches kamal-proxy back to the inactive colour using the legacy fallback" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_ok,
        ssh_ok("true\n"),
        ssh_ok,
      )

      command.run

      deploy_invocation = runner.invocations.find do |invocation|
        invocation.remote_command.try(&.includes?("kamal-proxy deploy myapp"))
      end
      deploy_invocation.should_not be_nil
      deploy_invocation = deploy_invocation.not_nil!
      remote_command = deploy_invocation.remote_command.not_nil!
      remote_command.should contain("--target myapp-green:3000")
      remote_command.should contain("--host myapp.example.com")
      remote_command.should contain("--tls")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/.meridian-color"))
      upload.should_not be_nil
      upload.not_nil!.input.should eq("green\n")
    end

    it "starts the inactive container when it is present but stopped" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_ok,
        ssh_ok("false\n"),
        ssh_ok("myapp-green\n"),
        ssh_ok,
      )

      command.run

      remote_commands_for(runner, "192.168.1.10").should contain("podman start myapp-green")
    end

    it "raises RollbackFailed when the inactive container is no longer present" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "missing\n"),
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /Rollback target myapp-green is not present/) do
        command.run
      end
    end

    it "rolls back to the previous release recorded in release-state.json" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)

      state = Meridian::Runtime::ReleaseState.new(
        current: Meridian::Runtime::ReleaseRecord.new(
          service: "myapp", role: "web", host: "192.168.1.10",
          color: "blue", image: "registry.example.com/myorg/myapp",
          release_id: "20260519T120000Z", deployed_at: "2026-05-19T12:00:00Z"
        ),
        previous: Meridian::Runtime::ReleaseRecord.new(
          service: "myapp", role: "web", host: "192.168.1.10",
          color: "green", image: "registry.example.com/myorg/myapp",
          release_id: "20260519T100000Z", deployed_at: "2026-05-19T10:00:00Z"
        )
      )

      runner.enqueue_results(
        ssh_ok(state.to_json),
        ssh_ok,           # container exists
        ssh_ok("true\n"), # container running
        ssh_ok,           # kamal-proxy deploy
        ssh_ok,           # write active-color
        ssh_ok,           # write legacy active-color
        ssh_ok,           # write release-state.json
      )

      command.run

      deploy = runner.invocations.find { |i| i.remote_command.try(&.includes?("kamal-proxy deploy myapp")) }
      deploy.not_nil!.remote_command.not_nil!.should contain("--target myapp-green:3000")

      release_upload = runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/release-state.json"))
      release_upload.should_not be_nil
      written = Meridian::Runtime::ReleaseState.from_json(release_upload.not_nil!.input.not_nil!)
      written.current.release_id.should eq("20260519T100000Z")
      written.current.color.should eq("green")
      written.previous.not_nil!.release_id.should eq("20260519T120000Z")
      written.previous.not_nil!.color.should eq("blue")
    end

    it "raises when release-state has no previous release" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)

      state = Meridian::Runtime::ReleaseState.new(
        current: Meridian::Runtime::ReleaseRecord.new(
          service: "myapp", role: "web", host: "192.168.1.10",
          color: "blue", image: "registry.example.com/myorg/myapp",
          release_id: "20260519T120000Z", deployed_at: "2026-05-19T12:00:00Z"
        )
      )

      runner.enqueue_results(ssh_ok(state.to_json))

      expect_raises(Meridian::Deploy::RollbackFailed, /No rollback-safe release retained/) do
        command.run
      end
    end
  end
end
