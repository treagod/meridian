require "../spec_helper"

def check_config : String
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
      workers:
        hosts:
          - 192.168.1.11
        cmd: bin/sidekiq

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest

    transfer:
      mode: stream

    env:
      secret:
        - DATABASE_URL

    ssh:
      user: deploy
    YAML
end

def build_check_command(
  content : String = check_config,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  local_image_probe : Meridian::Commands::Check::LocalImageProbe = ->(_image : String) { true },
  local_file_probe : Meridian::Commands::Check::LocalFileProbe = Meridian::Commands::Check::DEFAULT_LOCAL_FILE_PROBE,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(
    runner: runner,
    streaming_runner: FakeSSHStreamingRunner.new
  )
  Meridian::Commands::Check.new(
    config,
    ssh_executor: executor,
    output: output,
    error: output,
    local_image_probe: local_image_probe,
    local_file_probe: local_file_probe
  )
end

def check_ssh_fail(exit_code : Int32 = 1, stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr)
end

describe "Meridian::Commands::Check" do
  describe "#run" do
    it "passes when every configured host satisfies the probes" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(runner: runner, output: output)

      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok("true\n")
      )
      runner.enqueue_results_for_host(
        "192.168.1.11",
        ssh_ok,
        ssh_ok("podman version 5.0.0\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run.should be_true

      output.to_s.should contain("host")
      output.to_s.should contain("probe")
      output.to_s.should contain("192.168.1.10")
      output.to_s.should contain("192.168.1.11")
      output.to_s.should contain("Check passed")

      remote_commands = remote_commands_for(runner)
      remote_commands.should contain("true")
      remote_commands.should contain("podman --version")
      remote_commands.any? do |remote_command|
        remote_command.includes?("loginctl show-user deploy") &&
          remote_command.includes?("Linger=yes")
      end.should be_true
      remote_commands.should contain("sh -lc 'test -d ~/.config/containers/systemd && test -w ~/.config/containers/systemd'")
      remote_commands.should contain("sh -lc 'command -v zstd >/dev/null'")
      remote_commands.should contain("podman secret inspect DATABASE_URL")
      remote_commands.should contain(%(podman inspect --format '{{.State.Running}}' kamal-proxy))
      runner.invocations.all?(&.args.includes?("BatchMode=yes")).should be_true
    end

    it "fails when dependency, tool, secret, or proxy probes fail" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: myapp.example.com
                ssl: true

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest

          transfer:
            mode: stream

          env:
            secret:
              - DATABASE_URL
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.3.0\n"),
        ssh_ok,
        ssh_ok,
        check_ssh_fail(127, "", "zstd: command not found\n"),
        check_ssh_fail(1, "", "no such secret\n"),
        ssh_ok("false\n")
      )

      command.run.should be_false

      text = output.to_s
      text.should contain("podman")
      text.should contain("4.3.0 < 4.4")
      text.should contain("tool:zstd")
      text.should contain("secret:DATABASE_URL")
      text.should contain("kamal-proxy")
      text.should contain("not running")
      text.should contain("Check failed")
    end

    it "short-circuits a host when SSH connectivity fails" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(check_ssh_fail(255, "", "ssh: connect failed\n"))

      command.run.should be_false

      remote_commands_for(runner).should eq(["true"])
      output.to_s.should contain("SSH connection to deploy@192.168.1.10 failed")
    end

    it "checks all transfer tools for incremental mode" do
      runner = FakeSSHRunner.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          transfer:
            mode: incremental
          YAML
        runner: runner
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.0\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run.should be_true

      remote_commands = remote_commands_for(runner)
      remote_commands.should contain("sh -lc 'command -v zstd >/dev/null'")
      remote_commands.should contain("sh -lc 'command -v rsync >/dev/null'")
      remote_commands.should contain("sh -lc 'command -v skopeo >/dev/null'")
    end

    it "limits probes to the supplied targets" do
      runner = FakeSSHRunner.new
      command = build_check_command(runner: runner)
      targets = [Meridian::CLI::TargetSelector::Target.new(role: "workers", host: "192.168.1.11")]

      runner.enqueue_results_for_host(
        "192.168.1.11",
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run(targets).should be_true

      hosts = runner.invocations.map(&.host)
      hosts.uniq!
      hosts.should eq(["192.168.1.11"])
    end

    it "checks kamal-proxy when the web role has proxy configuration" do
      runner = FakeSSHRunner.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: myapp.example.com
                ssl: true
          YAML
        runner: runner
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.0\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("true\n")
      )

      command.run.should be_true

      remote_commands_for(runner).should contain(%(podman inspect --format '{{.State.Running}}' kamal-proxy))
      remote_commands_for(runner).should contain("podman image exists docker.io/library/alpine:3.21")
    end

    it "probes co-located accessory readiness" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.10
              network: myapp.network
              ready:
                tcp: 6379
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(ssh_ok, ssh_ok("podman version 4.4.0\n"))

      command.run.should be_true

      remote_commands_for(runner).any?(&.includes?("nc -z cache 6379")).should be_true
      output.to_s.should contain("accessory-readiness:cache")
    end

    it "fails when a co-located accessory is not ready" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.10
              network: myapp.network
              ready:
                tcp: 6379
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,                           # connectivity
        ssh_ok("podman version 4.4.0\n"), # podman version
        ssh_ok,                           # lingering
        ssh_ok,                           # quadlet-dir
        ssh_ok,                           # manifest-collisions
        check_ssh_fail                    # accessory-readiness
      )

      command.run.should be_false

      output.to_s.should contain("accessory-readiness:cache")
    end

    # A deploy gates on every accessory sharing the service network regardless of
    # `host:`, so resolution has to be reported even where no host probes it live.
    it "reports unresolvable readiness for a co-network accessory pinned to no host" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            search:
              image: myorg/custom:1
              network: myapp.network
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(ssh_ok, ssh_ok("podman version 4.4.0\n"))

      command.run.should be_false

      text = output.to_s
      text.should contain("accessory-readiness:search")
      text.should contain("cannot infer readiness")
      text.should contain("Check failed")
    end

    it "passes readiness resolution for a co-network accessory with an explicit ready block" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            search:
              image: myorg/custom:1
              network: myapp.network
              ready:
                tcp: 9200
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(ssh_ok, ssh_ok("podman version 4.4.0\n"))

      command.run.should be_true

      output.to_s.should contain("accessory-readiness:search")
    end

    it "fails when the readiness probe image is missing on a proxied host" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: myapp.example.com
                ssl: true
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,                           # connectivity
        ssh_ok("podman version 4.4.0\n"), # podman version
        ssh_ok,                           # lingering
        ssh_ok,                           # quadlet-dir
        ssh_ok("true\n"),                 # kamal-proxy running
        ssh_ok,                           # proxy-network exists
        check_ssh_fail                    # probe-image missing
      )

      command.run.should be_false

      output.to_s.should contain("probe-image")
    end

    it "fails when a remote service manifest owns an overlapping proxy route" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      other_manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: otherapp
        image: registry.example.com/myorg/otherapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            proxy:
              host: myapp.example.com
        YAML
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: myapp.example.com
                ssl: true
          YAML
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.0\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("true\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("#{other_manifest.to_json}\n")
      )

      command.run.should be_false

      text = output.to_s
      text.should contain("manifest-collisions")
      text.should contain("otherapp")
      text.should contain("overlaps")
    end

    it "fails when the same service name is registered with different ownership data" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      other_manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            proxy:
              host: other.example.com
        YAML
      command = build_check_command(
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
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.0\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("true\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok("#{other_manifest.to_json}\n")
      )

      command.run.should be_false

      output.to_s.should contain("service name myapp is already registered")
    end

    it "passes a local image row when the configured image is present locally" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      probed = [] of String
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          transfer:
            mode: stream
          YAML
        runner: runner,
        output: output,
        local_image_probe: ->(image : String) { probed << image; true }
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run.should be_true

      probed.should eq(["registry.example.com/myorg/myapp"])
      text = output.to_s
      text.should contain("local")
      text.should contain("image:registry.example.com/myorg/myapp")
      text.should contain("present")
      text.should contain("Check passed")
    end

    it "fails when the local image is missing for a registry-free transfer mode" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          transfer:
            mode: stream
          YAML
        runner: runner,
        output: output,
        local_image_probe: ->(_image : String) { false }
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run.should be_false

      text = output.to_s
      text.should contain("image:registry.example.com/myorg/myapp")
      text.should contain("not found locally")
      text.should contain("Check failed")
    end

    it "probes per-role image overrides as distinct local images" do
      runner = FakeSSHRunner.new
      probed = [] of String
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10
            workers:
              hosts:
                - 192.168.1.11
              image: registry.example.com/myorg/worker
              cmd: bin/sidekiq

          transfer:
            mode: incremental
          YAML
        runner: runner,
        local_image_probe: ->(image : String) { probed << image; true }
      )

      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok
      )
      runner.enqueue_results_for_host(
        "192.168.1.11",
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok
      )

      command.run.should be_true

      probed.sort.should eq([
        "registry.example.com/myorg/myapp",
        "registry.example.com/myorg/worker",
      ])
    end

    it "skips local image checks when transfer mode is registry" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      probed = [] of String
      command = build_check_command(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          transfer:
            mode: registry
          YAML
        runner: runner,
        output: output,
        local_image_probe: ->(image : String) { probed << image; false }
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok
      )

      command.run.should be_true

      probed.should be_empty
      output.to_s.should_not contain("image:")
    end

    it "passes a local file row when a files: source is readable" do
      with_tempdir do |dir|
        source_path = File.join(dir, "nginx.conf")
        File.write(source_path, "server { listen 80; }")

        runner = FakeSSHRunner.new
        output = IO::Memory.new
        command = build_check_command(
          content: <<-YAML,
            service: myapp
            image: registry.example.com/myorg/myapp

            servers:
              web:
                hosts:
                  - 192.168.1.10

            files:
              - source: #{source_path}
                destination: /home/deploy/nginx.conf
            YAML
          runner: runner,
          output: output
        )

        runner.enqueue_results(
          ssh_ok,
          ssh_ok("podman version 4.4.1\n"),
          ssh_ok,
          ssh_ok
        )

        command.run.should be_true

        text = output.to_s
        text.should contain("file:#{source_path}")
        text.should contain("readable")
        text.should contain("Check passed")
      end
    end

    it "fails when a files: source is missing locally" do
      missing_path = File.join(Dir.tempdir, "meridian_missing_#{Random::Secure.hex(8)}.conf")
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_check_command(
        content: <<-YAML,
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
        runner: runner,
        output: output
      )

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok
      )

      command.run.should be_false

      text = output.to_s
      text.should contain("file:#{missing_path}")
      text.should contain("not found or unreadable")
      text.should contain("Check failed")
    end

    # `File::Info.readable?` says yes to a directory, but the deploy reads the
    # source and fails with EISDIR - check has to agree with the deploy.
    it "fails when a files: source is a directory" do
      with_tempdir do |dir|
        source_path = File.join(dir, "config")
        Dir.mkdir(source_path)

        runner = FakeSSHRunner.new
        output = IO::Memory.new
        command = build_check_command(
          content: <<-YAML,
            service: myapp
            image: registry.example.com/myorg/myapp

            servers:
              web:
                hosts:
                  - 192.168.1.10

            files:
              - source: #{source_path}
                destination: /home/deploy/nginx.conf
            YAML
          runner: runner,
          output: output
        )

        runner.enqueue_results(
          ssh_ok,
          ssh_ok("podman version 4.4.1\n"),
          ssh_ok,
          ssh_ok
        )

        command.run.should be_false

        text = output.to_s
        text.should contain("file:#{source_path}")
        text.should contain("not found or unreadable")
        text.should contain("Check failed")
      end
    end

    it "skips file sources scoped to roles outside the selected targets" do
      missing_path = File.join(Dir.tempdir, "meridian_missing_#{Random::Secure.hex(8)}.conf")
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      content = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
          workers:
            hosts:
              - 192.168.1.11
            cmd: bin/sidekiq

        files:
          - source: #{missing_path}
            destination: /home/deploy/nginx.conf
            roles:
              - workers
        YAML
      command = build_check_command(content: content, runner: runner, output: output)

      runner.enqueue_results(
        ssh_ok,
        ssh_ok("podman version 4.4.1\n"),
        ssh_ok,
        ssh_ok
      )

      targets = [Meridian::CLI::TargetSelector::Target.new(role: "web", host: "192.168.1.10")]
      command.run(targets).should be_true

      output.to_s.should_not contain("file:")
    end
  end
end
