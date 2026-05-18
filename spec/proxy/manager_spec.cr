require "../spec_helper"

def build_proxy_manager(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Proxy::Manager.new(
    config,
    ssh_executor: executor,
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    output: output
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

    it "uploads the service network Quadlet to each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      uploads = runner.invocations.select(&.remote_command.==("cat > .config/containers/systemd/myapp.network"))
      uploads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
      uploads.each do |upload|
        upload_input = upload.input || raise "Expected upload input"
        upload_input.should contain("NetworkName=myapp")
      end
    end

    it "runs daemon-reload on each web host after uploading" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      reloads = runner.invocations.select(&.remote_command.==("systemctl --user daemon-reload"))
      reloads.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "starts kamal-proxy via systemctl on each web host" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      starts = runner.invocations.select(&.remote_command.==("systemctl --user start kamal-proxy.service"))
      starts.map(&.host).should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "does not touch worker hosts during proxy setup" do
      runner = FakeSSHRunner.new
      manager = build_proxy_manager(runner: runner)

      manager.setup

      touched_hosts = runner.invocations.compact_map(&.host)
      touched_hosts.uniq!
      touched_hosts.sort!
      touched_hosts.should eq(["192.168.1.10", "192.168.1.11"])
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
      commands.index("sudo install -d -m 0755 -o deploy -g deploy /var/lib/kamal-proxy").not_nil!.should be < commands.index("systemctl --user start kamal-proxy.service").not_nil!
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

    it "raises RemoveFailed when stopping the proxy fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "stop failed\n"),
      )
      manager = build_proxy_manager(runner: runner)

      expect_raises(Meridian::Proxy::RemoveFailed, /exit code 1/) do
        manager.remove
      end
    end
  end
end
