require "../spec_helper"

def build_proxy_manager(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  audit_logger : Meridian::Audit::Logger? = nil,
  drain_sleeper : Proc(Time::Span, Nil) = ->(_duration : Time::Span) { nil },
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Proxy::Manager.new(
    config,
    ssh_executor: executor,
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    output: output,
    audit_logger: audit_logger || FakeAuditLogger.new(config),
    drain_sleeper: drain_sleeper
  )
end

def proxy_assets_config : String
  <<-YAML
    service: myapp
    image: example.com/myapp
    servers:
      web:
        hosts: [192.168.1.10]
        proxy:
          host: myapp.example.com
    assets:
      host: static.example.com
      command: bin/build-assets
      output_dir: /app/public/assets
    YAML
end

describe "Meridian::Proxy::Manager" do
  describe "#setup" do
    it "installs service networks everywhere and Caddy only on web hosts" do
      runner = FakeSSHRunner.new
      build_proxy_manager(runner: runner).setup

      service_networks = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/myapp.network"))
      service_networks.map(&.host).should eq(["192.168.1.10", "192.168.1.11", "192.168.1.12"])

      quadlets = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/meridian-caddy.container"))
      quadlets.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])

      caddyfiles = runner.invocations.select(&.remote_command.==("cat > .config/containers/meridian-caddy/Caddyfile"))
      caddyfiles.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])

      routes = runner.invocations.select(&.remote_command.==("cat > .config/containers/meridian-caddy/routes/myapp.caddy.pending"))
      routes.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
      initial_route = remote_commands_for(runner, "192.168.1.10").find do |command|
        command.includes?("flock 9") && command.includes?("myapp.caddy.pending")
      end || raise "Expected initial route activation"
      initial_route.should contain("if test -f .config/containers/meridian-caddy/routes/myapp.caddy; then rm -f .config/containers/meridian-caddy/routes/myapp.caddy.pending")
    end

    it "uploads the service network to a co-network accessory host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.20
              network: myapp
          YAML
        runner: runner
      )

      manager.setup

      service_networks = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/myapp.network"))
      service_networks.map(&.host).should eq(["192.168.1.10", "192.168.1.20"])
      runner.invocations.none? do |invocation|
        invocation.host == "192.168.1.20" && invocation.remote_command == "cat > .config/containers/systemd/meridian-caddy.container"
      end.should be_true
    end

    it "checks flock, Caddy 2.11.2+, the private admin API, and reachability" do
      runner = FakeSSHRunner.new
      build_proxy_manager(runner: runner).setup
      commands = remote_commands_for(runner, "192.168.1.10")

      commands.should contain("sh -lc 'command -v flock >/dev/null'")
      commands.should contain("mkdir -p .config/containers/systemd .config/containers/meridian-caddy/routes .local/state/meridian/assets")
      commands.any? { |command| command.includes?("mkdir -p -- \"$path\"") && command.ends_with?("meridian %h/.local/share/meridian-caddy") }.should be_true
      commands.any? { |command| command.includes?("caddy version") && command.includes?("$3 >= 2") }.should be_true
      commands.should contain("curl --silent --show-error --fail --unix-socket .config/containers/meridian-caddy/admin.sock http://localhost/config/")
      commands.should contain("systemctl --user restart meridian-caddy.service")
      commands.any? { |command| command.includes?("curl --silent --show-error --retry 10") && command.ends_with?("--head http://127.0.0.1:80/") }.should be_true
    end

    it "uses custom data and HTTP settings for setup" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          proxy:
            http_port: 8080
            https_port: 8443
            data_dir: /srv/meridian-caddy
          YAML
        runner: runner
      )

      manager.setup

      commands = remote_commands_for(runner)
      commands.any?(&.ends_with?("meridian /srv/meridian-caddy")).should be_true
      commands.any? { |command| command.ends_with?("--head http://127.0.0.1:8080/") }.should be_true
    end

    it "refuses to migrate legacy kamal-proxy resources automatically" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_fail(1))
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          YAML
        runner: runner
      )

      expect_raises(Meridian::Proxy::SetupFailed, /Legacy kamal-proxy resources exist/) { manager.setup }
      remote_commands_for(runner).should_not contain("systemctl --user stop kamal-proxy.service")
    end

    it "normalizes remote setup failures" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_fail(1, stderr: "mkdir failed"))
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          YAML
        runner: runner
      )

      expect_raises(Meridian::Proxy::SetupFailed, /mkdir failed/) { manager.setup }
    end
  end

  describe "routes" do
    it "stages and atomically reloads an app route under flock" do
      runner = FakeSSHRunner.new
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"
      build_proxy_manager(runner: runner).switch("192.168.1.10", proxy, "myapp-blue:3000")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/meridian-caddy/routes/myapp.caddy.pending")) || raise "Expected route upload"
      (upload.input || raise "Expected route").should contain("reverse_proxy myapp-blue:3000")
      reload = remote_commands_for(runner).find(&.includes?("caddy reload")) || raise "Expected reload"
      reload.should contain("flock 9")
      reload.should contain("mv .config/containers/meridian-caddy/routes/myapp.caddy.pending .config/containers/meridian-caddy/routes/myapp.caddy")
      reload.should contain("mv .config/containers/meridian-caddy/routes/myapp.caddy.backup")
    end

    it "restores an old route or removes a first route when Caddy rejects a reload" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_fail(1, stderr: "bad config"))
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      expect_raises(Meridian::Proxy::RouteFailed, /bad config/) do
        build_proxy_manager(runner: runner).switch("192.168.1.10", proxy, "myapp-blue:3000")
      end
      reload = remote_commands_for(runner).last
      reload.should contain("mv .config/containers/meridian-caddy/routes/myapp.caddy.backup")
      reload.should contain("else rm -f .config/containers/meridian-caddy/routes/myapp.caddy")
    end

    it "accepts a committed target after an SSH disconnect" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        ssh_ok,
        ssh_fail(255),
        ssh_ok(%([{"address":"myapp-blue:3000","num_requests":0,"fails":0}])),
      )
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      build_proxy_manager(runner: runner).switch("192.168.1.10", proxy, "myapp-blue:3000")
    end

    it "leaves an unqueryable SSH disconnect explicitly uncertain" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_fail(255), ssh_fail(1))
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      expect_raises(Meridian::Proxy::SwitchUncertain, /both releases were left running/) do
        build_proxy_manager(runner: runner).switch("192.168.1.10", proxy, "myapp-blue:3000")
      end
    end

    it "rejects a disconnected switch when Caddy lacks the expected target" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_fail(255), ssh_ok("[]"))
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      expect_raises(Meridian::Proxy::RouteFailed, /was not committed/) do
        build_proxy_manager(runner: runner).switch("192.168.1.10", proxy, "myapp-blue:3000")
      end
    end

    it "confirms disconnected maintenance only when the removed target is absent" do
      config = load_config(FULL_CONFIG)
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      committed = FakeSSHRunner.new
      committed.enqueue_results(ssh_ok, ssh_fail(255), ssh_ok("[]"))
      build_proxy_manager(runner: committed).maintenance("192.168.1.10", proxy, "myapp-green:3000")

      uncertain = FakeSSHRunner.new
      uncertain.enqueue_results(
        ssh_ok,
        ssh_fail(255),
        ssh_ok(%([{"address":"myapp-green:3000","num_requests":0,"fails":0}])),
      )
      expect_raises(Meridian::Proxy::SwitchUncertain) do
        build_proxy_manager(runner: uncertain).maintenance("192.168.1.10", proxy, "myapp-green:3000")
      end
    end

    it "registers assets in an independent fragment" do
      runner = FakeSSHRunner.new
      build_proxy_manager(content: proxy_assets_config, runner: runner).register_assets("192.168.1.10")

      upload = runner.invocations.first
      upload.remote_command.should eq("cat > .config/containers/meridian-caddy/routes/myapp-assets.caddy.pending")

      # Served off the proxy's own read-only mount - no sidecar upstream.
      route = upload.input || raise "Expected route"
      route.should contain("root * /srv/assets/myapp/current")
      route.should contain("file_server")
      route.should_not contain("reverse_proxy")
    end
  end

  describe "#drain" do
    it "waits until the removed upstream has no in-flight requests" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        ssh_ok(%([{"address":"myapp-green:3000","num_requests":2,"fails":0}])),
        ssh_ok(%([{"address":"myapp-green:3000","num_requests":0,"fails":0}])),
      )
      sleeps = 0
      build_proxy_manager(runner: runner, drain_sleeper: ->(_duration : Time::Span) { sleeps += 1 })
        .drain("192.168.1.10", "myapp-green:3000")

      sleeps.should eq(1)
      remote_commands_for(runner).size.should eq(2)
    end

    it "warns and returns after the configured timeout" do
      runner = FakeSSHRunner.new
      busy = ssh_ok(%([{"address":"myapp-green:3000","num_requests":1,"fails":0}]))
      runner.enqueue_results(busy, busy)
      output = IO::Memory.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          proxy:
            drain_timeout: 2
          YAML
        runner: runner,
        output: output
      )

      manager.drain("192.168.1.10", "myapp-green:3000")
      output.to_s.should contain("stopping it anyway")
      remote_commands_for(runner).size.should eq(2)
    end

    it "returns immediately when the removed upstream is absent" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok("[]"))
      sleeps = 0

      build_proxy_manager(runner: runner, drain_sleeper: ->(_duration : Time::Span) { sleeps += 1 })
        .drain("192.168.1.10", "myapp-green:3000")

      sleeps.should eq(0)
      remote_commands_for(runner).size.should eq(1)
    end

    it "retries a failed upstream query" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_fail(1), ssh_ok("[]"))
      sleeps = 0

      build_proxy_manager(runner: runner, drain_sleeper: ->(_duration : Time::Span) { sleeps += 1 })
        .drain("192.168.1.10", "myapp-green:3000")

      sleeps.should eq(1)
      remote_commands_for(runner).size.should eq(2)
    end
  end

  describe "#remove" do
    it "removes only this service's routes before stopping an unshared Caddy" do
      runner = FakeSSHRunner.new
      build_proxy_manager(runner: runner).remove
      commands = remote_commands_for(runner, "192.168.1.10")

      commands.find(&.includes?("caddy reload")).should_not be_nil
      commands.should contain("rm -f .local/state/meridian/services/myapp/manifest.json")
      commands.should contain("systemctl --user stop meridian-caddy.service")
      commands.should contain("rm -f .config/containers/systemd/meridian-caddy.container")
      commands.none?(&.includes?(".local/share/meridian-caddy")).should be_true
      commands.none?(&.includes?("meridian-proxy.network")).should be_true
    end

    it "leaves shared Caddy running while another service manifest exists" do
      runner = FakeSSHRunner.new
      other = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: otherapp
        image: example.com/other
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: other.example.com
        YAML
      runner.enqueue_results_for_host("192.168.1.10", ssh_ok, ssh_ok, ssh_ok("#{other.to_json}\n"))
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          YAML
        runner: runner
      )

      manager.remove
      remote_commands_for(runner).should_not contain("systemctl --user stop meridian-caddy.service")
    end

    it "removes app and asset fragments in one reload" do
      runner = FakeSSHRunner.new
      build_proxy_manager(content: proxy_assets_config, runner: runner).remove

      reload = remote_commands_for(runner).find(&.includes?("caddy reload")) || raise "Expected route reload"
      reload.should contain("routes/myapp.caddy")
      reload.should contain("routes/myapp-assets.caddy")
    end

    it "restores removed fragments and normalizes a rejected reload" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_fail(1, stderr: "bad route"))

      expect_raises(Meridian::Proxy::RemoveFailed, /bad route/) do
        build_proxy_manager(content: proxy_assets_config, runner: runner).remove
      end

      reload = remote_commands_for(runner).first
      reload.should contain("myapp.caddy.removed")
      reload.should contain("myapp-assets.caddy.removed")
      reload.should contain("mv .config/containers/meridian-caddy/routes/myapp.caddy.removed")
    end

    it "stops shared Caddy with force even when another service exists" do
      runner = FakeSSHRunner.new
      other = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: otherapp
        image: example.com/other
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: other.example.com
        YAML
      runner.enqueue_results(ssh_ok, ssh_ok, ssh_ok("#{other.to_json}\n"))
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          YAML
        runner: runner
      )

      manager.remove(force: true)

      remote_commands_for(runner).should contain("systemctl --user stop meridian-caddy.service")
    end

    it "fails closed when other service manifests cannot be listed" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_ok, ssh_fail(1, stderr: "permission denied"))
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: example.com/myapp
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                host: example.com
          YAML
        runner: runner
      )

      expect_raises(Meridian::Proxy::RemoveFailed, /permission denied/) { manager.remove }

      commands = remote_commands_for(runner)
      commands.should_not contain("systemctl --user stop meridian-caddy.service")
      commands.should_not contain("rm -f .config/containers/systemd/meridian-caddy.container")
    end
  end
end
