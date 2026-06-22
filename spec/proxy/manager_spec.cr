require "../spec_helper"

def build_proxy_manager(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  audit_logger : Meridian::Audit::Logger? = nil,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Proxy::Manager.new(
    config,
    ssh_executor: executor,
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    output: output,
    audit_logger: audit_logger || FakeAuditLogger.new(config)
  )
end

describe "Meridian::Proxy::Manager" do
  describe "#setup" do
    it "uploads a kamal-proxy Quadlet file to each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container"))
      uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("ContainerName=kamal-proxy")
      end
    end

    it "uploads the service network Quadlet to every service host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/myapp.network"))
      uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.11", "192.168.1.12"])
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("NetworkName=myapp")
      end
    end

    it "uploads the service network Quadlet to co-network accessory hosts" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            db:
              image: docker.io/library/postgres:16
              host: 192.168.1.20
              network: myapp.network
          YAML
        runner: runner
      )

      manager.setup

      service_uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/myapp.network"))
      proxy_uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container"))

      service_uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.20"])
      proxy_uploads.map(&.host).should eq(["192.168.1.10"])
    end

    it "uploads the shared proxy network Quadlet to each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/meridian-proxy.network"))
      uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("NetworkName=meridian-proxy")
      end
    end

    it "reloads systemd after network and proxy uploads" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      reloads = runner.invocations.select(&.remote_command.==("systemctl --user daemon-reload"))
      reloads.map(&.host).should eq(["192.168.1.10", "192.168.1.11", "192.168.1.12", "192.168.1.10", "192.168.1.11"])
    end

    it "starts the service network unit after reloading systemd" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      starts = runner.invocations.select(&.remote_command.==("systemctl --user start myapp-network.service"))
      starts.map(&.host).should eq(["192.168.1.10", "192.168.1.11", "192.168.1.12"])

      commands = remote_commands_for(runner, "192.168.1.10")
      reload_index = commands.index!("systemctl --user daemon-reload")
      start_index = commands.index!("systemctl --user start myapp-network.service")
      start_index.should be > reload_index
    end

    it "starts kamal-proxy via systemctl on each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      starts = runner.invocations.select(&.remote_command.==("systemctl --user start kamal-proxy.service"))
      starts.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "materializes the shared proxy network before starting kamal-proxy" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      commands = remote_commands_for(runner, "192.168.1.10")
      network_command = commands.find do |command|
        command.includes?("systemctl --user start meridian-proxy-network.service") &&
          command.includes?("podman network exists meridian-proxy") &&
          command.includes?("podman network create meridian-proxy")
      end

      network_command.should_not be_nil
      commands.index!(value!(network_command)).should be < commands.index!("systemctl --user start kamal-proxy.service")
    end

    it "connects a running legacy proxy container to the shared proxy network" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.any? do |command|
        command.includes?("podman container exists kamal-proxy") &&
          command.includes?("podman network connect meridian-proxy kamal-proxy")
      end.should be_true
    end

    it "does not install kamal-proxy on worker hosts" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      proxy_uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container"))
      proxy_starts = runner.invocations.select(&.remote_command.==("systemctl --user start kamal-proxy.service"))

      proxy_uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
      proxy_starts.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "raises SetupFailed when uploading the Quadlet fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "upload failed\n"),
      )
      manager = build_proxy_manager(runner: runner)

      expect_raises(Meridian::Proxy::SetupFailed, /exit code 1/) do
        manager.setup
      end
    end

    it "raises SetupFailed when starting the proxy fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "start failed\n"),
      )
      manager = build_proxy_manager(runner: runner)

      expect_raises(Meridian::Proxy::SetupFailed, /exit code 1/) do
        manager.setup
      end
    end

    it "includes the default data_dir volume in the uploaded Quadlet" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container"))
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("Volume=/var/lib/kamal-proxy:/var/lib/kamal-proxy")
      end
    end

    it "creates the default proxy data_dir before starting the proxy" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      commands = runner.invocations.select { |invocation| invocation.host == "192.168.1.10" }.compact_map(&.remote_command)
      commands.should contain("sudo install -d -m 0755 -o deploy -g deploy /var/lib/kamal-proxy")
      commands.index!("sudo install -d -m 0755 -o deploy -g deploy /var/lib/kamal-proxy").should be < commands.index!("systemctl --user start kamal-proxy.service")
    end

    it "uses default proxy settings when the root proxy block is omitted" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: myapp.example.com
          YAML
        runner: runner
      )

      manager.setup

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container")) || raise "Expected proxy upload"
      upload_input = upload.input || raise "Expected upload input"
      upload_input.should contain("Image=docker.io/basecamp/kamal-proxy:v0.9.2")
      upload_input.should contain("PublishPort=80:80")
      upload_input.should contain("PublishPort=443:443")
      runner.invocations.compact_map(&.remote_command).should contain("sudo install -d -m 0755 -o deploy -g deploy /var/lib/kamal-proxy")
    end

    it "uses a custom data_dir in the uploaded Quadlet when configured" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
            data_dir: /custom/proxy-data
          YAML
        runner: runner
      )

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/kamal-proxy.container"))
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("Volume=/custom/proxy-data:/custom/proxy-data")
      end
      runner.invocations.compact_map(&.remote_command).should contain("sudo install -d -m 0755 -o deploy -g deploy /custom/proxy-data")
    end

    it "raises SetupFailed when the proxy probe fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "curl failed\n"),
      )
      manager = build_proxy_manager(runner: runner)

      expect_raises(Meridian::Proxy::SetupFailed, /exit code 1/) do
        manager.setup
      end
    end

    it "uses configured SSH user, port, and first key for proxy setup" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest

          ssh:
            user: deployer
            port: 2222
            keys:
              - /tmp/id_ed25519
            proxy_jump: bastion.example.com
            connect_timeout: 12
            keepalive: true
            keepalive_interval: 45
          YAML
        runner: runner
      )

      manager.setup

      runner.invocations.first.args.should eq([
        "-p",
        "2222",
        "-i",
        "/tmp/id_ed25519",
        "-J",
        "bastion.example.com",
        "-o",
        "ConnectTimeout=12",
        "-o",
        "ServerAliveInterval=45",
        "-o",
        "ServerAliveCountMax=3",
        "deployer@192.168.1.10",
        "mkdir -p .config/containers/systemd",
      ])
    end

    it "expands home-relative SSH key paths for proxy setup" do
      with_tempdir do |dir|
        old_home = ENV["HOME"]?
        ENV["HOME"] = dir
        begin
          runner = FakeSSHRunner.new
          manager = build_proxy_manager(
            content: <<-YAML,
              service: myapp
              image: registry.example.com/myorg/myapp

              servers:
                web:
                  hosts:
                    - 192.168.1.10

              proxy:
                image: ghcr.io/basecamp/kamal-proxy:latest

              ssh:
                user: deploy
                keys:
                  - ~/.ssh/id_ed25519
              YAML
            runner: runner
          )

          manager.setup

          runner.invocations.first.args.should contain(File.join(dir, ".ssh/id_ed25519"))
        ensure
          if old_home
            ENV["HOME"] = old_home
          else
            ENV.delete("HOME")
          end
        end
      end
    end
  end

  describe "#remove" do
    it "stops kamal-proxy on each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.remove

      stops = runner.invocations.select(&.remote_command.==("systemctl --user stop kamal-proxy.service"))
      stops.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "removes the kamal-proxy Quadlet file from each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.remove

      removals = runner.invocations.select(&.remote_command.==("rm -f .config/containers/systemd/kamal-proxy.container"))
      removals.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])

      reloads = runner.invocations.select(&.remote_command.==("systemctl --user daemon-reload"))
      reloads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "leaves the shared proxy running when another service manifest exists" do
      runner = FakeSSHRunner.new
      other_manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: otherapp
        image: registry.example.com/myorg/otherapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            proxy:
              host: other.example.com
        YAML
      runner.enqueue_results_for_host(
        "192.168.1.10",
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "#{other_manifest.to_json}\n", stderr: "")
      )
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          YAML
        runner: runner
      )

      manager.remove

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should contain("rm -f .local/state/meridian/services/myapp/manifest.json")
      commands.should_not contain("systemctl --user stop kamal-proxy.service")
      commands.should_not contain("rm -f .config/containers/systemd/kamal-proxy.container")
    end

    it "stops the shared proxy with force even when another service manifest exists" do
      runner = FakeSSHRunner.new
      other_manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: otherapp
        image: registry.example.com/myorg/otherapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            proxy:
              host: other.example.com
        YAML
      runner.enqueue_results_for_host(
        "192.168.1.10",
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "#{other_manifest.to_json}\n", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: "")
      )
      manager = build_proxy_manager(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          YAML
        runner: runner
      )

      manager.remove(force: true)

      remote_commands_for(runner, "192.168.1.10").should contain("systemctl --user stop kamal-proxy.service")
    end

    it "raises RemoveFailed when stopping the proxy fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "stop failed\n"),
      )
      manager = build_proxy_manager(runner: runner)

      expect_raises(Meridian::Proxy::RemoveFailed, /exit code 1/) do
        manager.remove
      end
    end
  end
end
