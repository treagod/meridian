require "../spec_helper"

PRUNE_CONFIG = <<-YAML
  service: myapp
  image: registry.example.com/myorg/myapp

  servers:
    web:
      hosts:
        - 192.168.1.10
      proxy:
        host: myapp.example.com
  YAML

def build_prune_command(
  content : String = PRUNE_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  input : IO = IO::Memory.new("y\n"),
)
  config = load_config(content)
  Meridian::Commands::Prune.new(
    config,
    ssh_executor: Meridian::SSH::Executor.new(runner: runner),
    output: output,
    error: output,
    audit_logger: FakeAuditLogger.new(config),
    input: input
  )
end

def manifest_recording(content : String, extra : Array(String)) : String
  manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(content))
  manifest.generated_files.concat(extra)
  manifest.to_json
end

describe Meridian::Commands::Prune do
  describe "#run" do
    it "does nothing when the recorded manifest matches the configuration" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [] of String)))

      build_prune_command(runner: runner, output: output).run.should be_false

      output.to_s.should contain("Nothing to prune")
      remote_commands_for(runner).none?(&.starts_with?("rm -f")).should be_true
    end

    it "does nothing when the host has no manifest at all" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_fail(1, "", "No such file\n"))

      build_prune_command(runner: runner).run.should be_false

      remote_commands_for(runner).none?(&.starts_with?("rm -f")).should be_true
    end

    it "stops the unit before removing a stale container Quadlet" do
      runner = FakeSSHRunner.new
      stale = ".config/containers/systemd/myapp-worker.container"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      build_prune_command(runner: runner).run.should be_true

      commands = remote_commands_for(runner)
      stop_index = commands.index("systemctl --user stop myapp-worker.service") ||
                   raise "Expected the unit to be stopped"
      remove_index = commands.index("rm -f #{stale}") || raise "Expected the file to be removed"

      stop_index.should be < remove_index
      commands.should contain("systemctl --user daemon-reload")
    end

    it "derives the unit name from the Quadlet kind" do
      runner = FakeSSHRunner.new
      stale = [
        ".config/containers/systemd/myapp-old.network",
        ".config/containers/systemd/myapp-assets.volume",
      ]
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, stale)))

      build_prune_command(runner: runner).run.should be_true

      commands = remote_commands_for(runner)
      commands.should contain("systemctl --user stop myapp-old-network.service")
      commands.should contain("systemctl --user stop myapp-assets-volume.service")
    end

    it "removes a volume Quadlet but keeps the Podman volume" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      stale = ".config/containers/systemd/myapp-assets.volume"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      build_prune_command(runner: runner, output: output).run.should be_true

      commands = remote_commands_for(runner)
      commands.should contain("rm -f #{stale}")
      commands.none?(&.includes?("podman volume rm")).should be_true
      output.to_s.should contain("systemd-myapp-assets")
    end

    it "removes a plain generated file without touching systemd" do
      runner = FakeSSHRunner.new
      stale = ".config/containers/myapp-assets-caddy/Caddyfile"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      build_prune_command(runner: runner).run.should be_true

      commands = remote_commands_for(runner)
      commands.should contain("rm -f #{stale}")
      commands.none?(&.starts_with?("systemctl --user stop")).should be_true
      commands.none?(&.includes?("daemon-reload")).should be_true
    end

    it "refuses paths outside the allowed roots" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      stale = ["/etc/passwd", ".config/containers/../../.ssh/authorized_keys"]
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, stale)))

      build_prune_command(runner: runner, output: output).run.should be_false

      commands = remote_commands_for(runner)
      commands.none?(&.starts_with?("rm -f")).should be_true
      output.to_s.should contain("Refusing to remove /etc/passwd")
      output.to_s.should contain("authorized_keys")
    end

    it "aborts without removing anything when the confirmation is declined" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      stale = ".config/containers/systemd/myapp-worker.container"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      command = build_prune_command(runner: runner, output: output, input: IO::Memory.new("n\n"))
      command.run.should be_false

      remote_commands_for(runner).none?(&.starts_with?("rm -f")).should be_true
      output.to_s.should contain("Aborted.")
    end

    it "skips the confirmation with force" do
      runner = FakeSSHRunner.new
      stale = ".config/containers/systemd/myapp-worker.container"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      command = build_prune_command(runner: runner, input: IO::Memory.new(""))
      command.run(force: true).should be_true

      remote_commands_for(runner).should contain("rm -f #{stale}")
    end

    it "never removes the manifest itself" do
      runner = FakeSSHRunner.new
      stale = ".config/containers/systemd/myapp-worker.container"
      runner.enqueue_results(ssh_ok(manifest_recording(PRUNE_CONFIG, [stale])))

      build_prune_command(runner: runner).run.should be_true

      remote_commands_for(runner)
        .none?(&.includes?("rm -f .local/state/meridian/services/myapp/manifest.json"))
        .should be_true
    end
  end
end
