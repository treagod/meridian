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
      image: docker.io/library/caddy:2.11.4-alpine
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
      image: docker.io/library/caddy:2.11.4-alpine
    YAML
end

def fast_health_rollback_config : String
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
            interval: 0
            timeout: 5
            retries: 1
            required_successes: 1

    proxy:
      image: docker.io/library/caddy:2.11.4-alpine
    YAML
end

def rollback_release_state : Meridian::Runtime::ReleaseState
  Meridian::Runtime::ReleaseState.new(
    current: Meridian::Runtime::ReleaseRecord.new(
      service: "myapp", role: "web", host: "192.168.1.10",
      color: "blue", image: "registry.example.com/myorg/myapp:release-b",
      release_id: "20260519T120000Z", deployed_at: "2026-05-19T12:00:00Z"
    ),
    previous: Meridian::Runtime::ReleaseRecord.new(
      service: "myapp", role: "web", host: "192.168.1.10",
      color: "green", image: "registry.example.com/myorg/myapp:release-a",
      release_id: "20260519T100000Z", deployed_at: "2026-05-19T10:00:00Z"
    )
  )
end

def build_rollback_command(
  content : String = rollback_config,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  audit_logger : Meridian::Audit::Logger? = nil,
  proxy_manager : Meridian::Proxy::Manager? = nil,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(
    runner: runner,
    streaming_runner: FakeSSHStreamingRunner.new
  )
  Meridian::Commands::Rollback.new(
    config,
    ssh_executor: executor,
    output: output,
    error: output,
    audit_logger: audit_logger || FakeAuditLogger.new(config),
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    health_sleeper: ->(_duration : Time::Span) { nil },
    proxy_manager: proxy_manager
  )
end

def enqueue_release_rollback_success(runner : FakeSSHRunner) : Nil
  runner.enqueue_results(
    ssh_ok(rollback_release_state.to_json),
    ssh_ok, ssh_ok, ssh_ok, ssh_ok,
    ssh_ok("ok"), ssh_ok("ok"), ssh_ok("ok"),
    ssh_ok, ssh_ok, ssh_ok("[]"), ssh_ok, ssh_ok, ssh_ok, ssh_ok, ssh_ok, ssh_ok,
  )
end

describe "Meridian::Commands::Rollback" do
  describe "#run" do
    it "rejects recreate before contacting the host" do
      runner = FakeSSHRunner.new
      content = <<-YAML
        service: myapp
        strategy: recreate
        image: registry.example.com/myorg/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: myapp.example.com
        YAML
      command = build_rollback_command(content: content, runner: runner)

      ex = expect_raises(Meridian::Deploy::RollbackFailed, /persistent data/) do
        command.run
      end

      ex.message.to_s.should contain("database")
      ex.message.to_s.should contain("persistent volumes")
      runner.invocations.should be_empty
    end

    it "reads the active colour from the service-scoped state path on each host when no release state is present" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(runner: runner)
      runner.enqueue_results_for_host("192.168.1.10", ssh_fail(1, "", "No such file\n"), ssh_ok("blue\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok, ssh_ok("[]"))
      runner.enqueue_results_for_host("192.168.1.11", ssh_fail(1, "", "No such file\n"), ssh_ok("green\n"), ssh_ok, ssh_ok("true\n"), ssh_ok, ssh_ok, ssh_ok("[]"))

      command.run

      reads = runner.invocations.select(&.remote_command.==("cat .local/state/meridian/services/myapp/active-color"))
      reads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "switches Caddy back to the inactive colour using the legacy fallback" do
      runner = FakeSSHRunner.new
      config = load_config(single_host_rollback_config)
      manager = FakeProxyManager.new(config)
      command = build_rollback_command(content: single_host_rollback_config, runner: runner, proxy_manager: manager)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_ok,
        ssh_ok("true\n"),
      )

      command.run

      manager.switch_calls.should eq([{host: "192.168.1.10", target: "myapp-green:3000"}])
      manager.drain_calls.should eq([{host: "192.168.1.10", target: "myapp-blue:3000"}])

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/.meridian-color"))
      upload.should_not be_nil
      value!(upload).input.should eq("green\n")
    end

    it "starts the surviving inactive container in the legacy fallback when it is stopped" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_ok,
        ssh_ok("false\n"),
        ssh_ok("myapp-green\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("[]"),
      )

      command.run

      remote_commands_for(runner, "192.168.1.10").should contain("podman start myapp-green")
    end

    it "raises RollbackFailed in the legacy fallback when the inactive container is no longer present" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_fail(1, "", "missing\n"),
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /Rollback target myapp-green is not present/) do
        command.run
      end
    end

    it "reconstructs the previous release from release-state.json instead of requiring its container" do
      runner = FakeSSHRunner.new
      audit = FakeAuditLogger.new(load_config(single_host_rollback_config))
      command = build_rollback_command(content: single_host_rollback_config, runner: runner, audit_logger: audit)

      enqueue_release_rollback_success(runner)

      command.run

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should contain("podman image exists registry.example.com/myorg/myapp:release-a")
      commands.should contain("systemctl --user start myapp-green.service")
      commands.should_not contain("podman container exists myapp-green")
      commands.should_not contain("podman start myapp-green")

      quadlet_upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/myapp-green.container"))
      quadlet_upload.should_not be_nil
      quadlet_content = value!(value!(quadlet_upload).input)
      quadlet_content.should contain("Image=registry.example.com/myorg/myapp:release-a")
      quadlet_content.should contain("ContainerName=myapp-green")

      deploy = runner.invocations.find(&.remote_command.==("cat > .config/containers/meridian-caddy/routes/myapp.caddy.pending"))
      value!(value!(deploy).input).should contain("reverse_proxy myapp-green:3000")
    end

    it "switches the proxy only after the reconstructed release passes its health check, then retires the old release" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)

      enqueue_release_rollback_success(runner)

      command.run

      commands = remote_commands_for(runner, "192.168.1.10")
      last_health = value!(commands.rindex(&.includes?("wget -q -O-")))
      proxy_switch = value!(commands.index(&.includes?("caddy reload")))
      stop_old = value!(commands.index("systemctl --user stop myapp-blue.service"))

      last_health.should be < proxy_switch
      proxy_switch.should be < stop_old
      commands.should contain("rm -f .config/containers/systemd/myapp-blue.container")
    end

    it "swaps release state, records the active colour, and audits after a successful rollback" do
      runner = FakeSSHRunner.new
      audit = FakeAuditLogger.new(load_config(single_host_rollback_config))
      command = build_rollback_command(content: single_host_rollback_config, runner: runner, audit_logger: audit)

      enqueue_release_rollback_success(runner)

      command.run

      color_upload = runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/active-color"))
      value!(value!(color_upload).input).should eq("green\n")

      release_upload = runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/release-state.json"))
      release_upload.should_not be_nil
      written = Meridian::Runtime::ReleaseState.from_json(value!(value!(release_upload).input))
      written.current.release_id.should eq("20260519T100000Z")
      written.current.color.should eq("green")
      value!(written.previous).release_id.should eq("20260519T120000Z")
      value!(written.previous).color.should eq("blue")

      rollbacks = audit.recorded.select(&.action.==("rollback"))
      rollbacks.size.should eq(1)
      rollbacks.first.detail.should eq("to release 20260519T100000Z (green)")
    end

    it "cleans up the reconstructed candidate and keeps the active release when the health check fails" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: fast_health_rollback_config, runner: runner)

      runner.enqueue_results(
        ssh_ok(rollback_release_state.to_json),
        ssh_ok,                          # podman image exists
        ssh_ok,                          # upload reconstructed quadlet
        ssh_ok,                          # daemon-reload
        ssh_ok,                          # systemctl start
        ssh_fail(1, "", "unreachable\n") # health probe fails
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /Health check failed for myapp-green/) do
        command.run
      end

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should contain("systemctl --user stop myapp-green.service")
      commands.should contain("rm -f .config/containers/systemd/myapp-green.container")
      commands.should_not contain("systemctl --user stop myapp-blue.service")
      commands.none?(&.includes?("caddy reload")).should be_true

      runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/release-state.json")).should be_nil
      runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/active-color")).should be_nil
    end

    it "cleans up the reconstructed candidate when the proxy switch fails" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: fast_health_rollback_config, runner: runner)

      runner.enqueue_results(
        ssh_ok(rollback_release_state.to_json),
        ssh_ok,                       # podman image exists
        ssh_ok,                       # upload reconstructed quadlet
        ssh_ok,                       # daemon-reload
        ssh_ok,                       # systemctl start
        ssh_ok("ok"),                 # health probe passes
        ssh_ok,                       # upload pending Caddy route
        ssh_fail(1, "", "no route\n") # Caddy reload fails
      )

      expect_raises(Meridian::Deploy::RollbackFailed) do
        command.run
      end

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should contain("systemctl --user stop myapp-green.service")
      commands.should contain("rm -f .config/containers/systemd/myapp-green.container")
      commands.should_not contain("systemctl --user stop myapp-blue.service")
      runner.invocations.find(&.remote_command.==("cat > .local/state/meridian/services/myapp/release-state.json")).should be_nil
    end

    it "keeps both releases and state unchanged when a reconstructed switch is uncertain" do
      runner = FakeSSHRunner.new
      config = load_config(single_host_rollback_config)
      manager = FakeProxyManager.new(
        config,
        switch_error: Meridian::Proxy::SwitchUncertain.new("inspect Caddy upstreams")
      )
      command = build_rollback_command(
        content: single_host_rollback_config,
        runner: runner,
        proxy_manager: manager
      )
      runner.enqueue_results(
        ssh_ok(rollback_release_state.to_json),
        ssh_ok, ssh_ok, ssh_ok, ssh_ok,
        ssh_ok("ok"), ssh_ok("ok"), ssh_ok("ok"),
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /inspect Caddy upstreams/) { command.run }

      commands = remote_commands_for(runner)
      commands.should_not contain("systemctl --user stop myapp-green.service")
      commands.should_not contain("systemctl --user stop myapp-blue.service")
      commands.should_not contain("cat > .local/state/meridian/services/myapp/active-color")
      commands.should_not contain("cat > .local/state/meridian/services/myapp/release-state.json")
    end

    it "normalizes an uncertain legacy switch without stopping either colour" do
      runner = FakeSSHRunner.new
      config = load_config(single_host_rollback_config)
      manager = FakeProxyManager.new(
        config,
        switch_error: Meridian::Proxy::SwitchUncertain.new("inspect Caddy upstreams")
      )
      command = build_rollback_command(
        content: single_host_rollback_config,
        runner: runner,
        proxy_manager: manager
      )
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("blue\n"),
        ssh_ok,
        ssh_ok("true\n"),
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /inspect Caddy upstreams/) { command.run }

      commands = remote_commands_for(runner)
      commands.should_not contain("podman stop myapp-blue")
      commands.should_not contain("podman stop myapp-green")
      commands.should_not contain("cat > .local/state/meridian/services/myapp/active-color")
    end

    it "raises RollbackFailed before reconstructing when the previous image is gone from the host" do
      runner = FakeSSHRunner.new
      command = build_rollback_command(content: single_host_rollback_config, runner: runner)

      runner.enqueue_results(
        ssh_ok(rollback_release_state.to_json),
        ssh_fail(1, "", "image not known\n"),
      )

      expect_raises(Meridian::Deploy::RollbackFailed, /no longer present on 192\.168\.1\.10/) do
        command.run
      end

      runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/myapp-green.container")).should be_nil
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
