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
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(
    runner: runner,
    streaming_runner: FakeSSHStreamingRunner.new
  )
  Meridian::Commands::Check.new(config, ssh_executor: executor, output: output, error: output)
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
    end
  end
end
