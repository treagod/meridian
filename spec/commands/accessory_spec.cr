require "../spec_helper"

def build_accessory_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  streaming_runner : FakeSSHStreamingRunner = FakeSSHStreamingRunner.new,
  output : IO = IO::Memory.new,
  audit_logger : Meridian::Audit::Logger? = nil,
  input : IO = IO::Memory.new(""),
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)
  Meridian::Commands::Accessory.new(
    config,
    ssh_executor: executor,
    output: output,
    error: output,
    audit_logger: audit_logger || FakeAuditLogger.new(config),
    input: input
  )
end

MANIFEST_LIST_COMMAND = Process.quote_posix(Meridian::Runtime::ServiceManifest.list_command)

# A `postgres` accessory shared by convention: identical declaration in every
# service that depends on it.
def shared_postgres_config(
  service : String = "nextcloud",
  image : String = "docker.io/library/postgres:18-alpine",
  volume : String = "postgres-data:/var/lib/postgresql/data",
) : String
  <<-YAML
    service: #{service}
    image: registry.example.com/myorg/#{service}

    servers:
      web:
        hosts:
          - 192.168.1.10

    accessories:
      postgres:
        image: #{image}
        host: 192.168.1.20
        network: postgres
        volumes:
          - #{volume}
    YAML
end

# The remote listing `find` emits one manifest JSON document per line.
def manifest_listing(
  *services : String,
  image : String = "docker.io/library/postgres:18-alpine",
  volume : String = "postgres-data:/var/lib/postgresql/data",
) : Meridian::SSH::Result
  documents = services.map do |service|
    content = shared_postgres_config(service: service, image: image, volume: volume)
    Meridian::Runtime::ServiceManifest.from_config(load_config(content)).to_json
  end

  ssh_ok("#{documents.join("\n")}\n")
end

def rendered_accessory_quadlet(content : String, name : String) : String
  config = load_config(content)
  Meridian::Quadlet::Generator.new(config).accessory_container_file(name, value!(config.accessories)[name])
end

def accessory_clear_env_config : String
  <<-YAML
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
        port: "5432:5432"
        volumes:
          - pgdata:/var/lib/postgresql/data
        env:
          clear:
            POSTGRES_DB: meridian
        cmd: postgres -c shared_buffers=256MB
    YAML
end

def accessory_missing_host_config : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10

    accessories:
      db:
        image: docker.io/library/postgres:16
    YAML
end

def co_network_accessory_config : String
  <<-YAML
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
end

def accessory_commands_for(runner : FakeSSHRunner, host : String) : Array(String)
  runner.invocations.compact_map do |invocation|
    next unless invocation.host == host

    invocation.remote_command
  end
end

describe "Meridian::Commands::Accessory" do
  describe "#start" do
    it "uploads a Quadlet file for the accessory to its designated host" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/db.container"))
      upload.should_not be_nil
      input = value!(upload).input || raise "Expected uploaded Quadlet content"
      input.should contain("Image=docker.io/library/postgres:16")
      input.should contain("ContainerName=db")
    end

    it "targets the host defined in the accessory configuration" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      runner.invocations.compact_map(&.host).uniq!.should eq(["192.168.1.20"])
    end

    it "runs daemon-reload before starting the accessory" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      accessory_commands_for(runner, "192.168.1.20").should eq([
        MANIFEST_LIST_COMMAND,
        "mkdir -p .config/containers/systemd",
        "cat > .config/containers/systemd/db.container",
        "systemctl --user daemon-reload",
        "systemctl --user start db.service",
      ])
    end

    it "publishes the configured port" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/db.container"))
      upload.should_not be_nil
      input = value!(upload).input || raise "Expected uploaded Quadlet content"
      input.should contain("PublishPort=5432:5432")
    end

    it "mounts the configured volume" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/db.container"))
      upload.should_not be_nil
      input = value!(upload).input || raise "Expected uploaded Quadlet content"
      input.should contain("Volume=pgdata:/var/lib/postgresql/data")
    end

    it "fails before uploading when setup has not created a referenced service network" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_fail(1))
      command = build_accessory_command(content: co_network_accessory_config, runner: runner)

      expect_raises(ArgumentError, /Run `meridian setup` before `meridian accessory start`/) do
        command.start("db")
      end

      accessory_commands_for(runner, "192.168.1.20").should eq([
        MANIFEST_LIST_COMMAND,
        "podman network exists myapp",
      ])
    end

    it "never creates the private service network itself" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: co_network_accessory_config, runner: runner)

      command.start("db")

      commands = accessory_commands_for(runner, "192.168.1.20")
      commands.should contain("podman network exists myapp")
      commands.any?(&.includes?("podman network create")).should be_false
    end

    it "creates a missing custom accessory network" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.start("postgres")

      ensure_network = accessory_commands_for(runner, "192.168.1.20").find(&.includes?("podman network"))
      value!(ensure_network).should eq(
        "sh -lc 'podman network exists postgres || podman network create postgres >/dev/null'"
      )
    end

    it "reuses an existing custom accessory network without recreating it" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.start("postgres")

      # `podman network exists || podman network create` short-circuits on the
      # host, so idempotence is the shell's job and Meridian issues one command
      # either way.
      accessory_commands_for(runner, "192.168.1.20").count(&.includes?("podman network")).should eq(1)
    end

    it "reuses an accessory another service already declares identically" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      runner.enqueue_results(ssh_ok(rendered_accessory_quadlet(shared_postgres_config, "postgres")))
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.start("postgres")

      accessory_commands_for(runner, "192.168.1.20").should contain(
        "systemctl --user start postgres.service"
      )
    end

    it "refuses to overwrite an accessory another service declares differently" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(
        content: shared_postgres_config(image: "docker.io/library/postgres:17-alpine"),
        runner: runner
      )

      expect_raises(ArgumentError, /conflicts with the definition already registered by service 'freshrss'/) do
        command.start("postgres")
      end

      commands = accessory_commands_for(runner, "192.168.1.20")
      commands.should eq([MANIFEST_LIST_COMMAND])
    end

    it "names the differing fields in a conflict" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(
        content: shared_postgres_config(image: "docker.io/library/postgres:17-alpine"),
        runner: runner
      )

      message = expect_raises(ArgumentError) { command.start("postgres") }.message.to_s

      message.should contain("Different fields:")
      message.should contain("image:")
      message.should contain("current:  docker.io/library/postgres:17-alpine")
      message.should contain("existing: docker.io/library/postgres:18-alpine")
    end

    it "refuses when the on-host unit of a shared accessory differs from the request" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      runner.enqueue_results(ssh_ok("[Container]\nImage=docker.io/library/postgres:15\n"))
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      expect_raises(ArgumentError, /will not overwrite/) do
        command.start("postgres")
      end

      accessory_commands_for(runner, "192.168.1.20").any?(&.starts_with?("cat > ")).should be_false
    end

    it "updates freely when no other service references the accessory" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.start("postgres")

      accessory_commands_for(runner, "192.168.1.20").should contain(
        "cat > .config/containers/systemd/postgres.container"
      )
    end

    it "raises UnknownAccessory when the named accessory does not exist in the config" do
      command = build_accessory_command

      expect_raises(Meridian::Config::UnknownAccessory, /Unknown accessory: redis/) do
        command.start("redis")
      end
    end

    it "raises an error when the accessory host is missing" do
      command = build_accessory_command(content: accessory_missing_host_config)

      expect_raises(ArgumentError, /Accessory db is missing required host/) do
        command.start("db")
      end
    end
  end

  describe "#stop" do
    it "stops the accessory systemd service" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.stop("db")

      accessory_commands_for(runner, "192.168.1.20").should eq([
        MANIFEST_LIST_COMMAND,
        "systemctl --user stop db.service",
      ])
    end

    it "does not affect any web or worker services" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.stop("db")

      commands = accessory_commands_for(runner, "192.168.1.20")
      commands.should_not contain("systemctl --user stop myapp-blue.service")
      commands.should_not contain("systemctl --user stop myapp-green.service")
      commands.any?(&.includes?("meridian-caddy")).should be_false
    end
  end

  describe "#stop shared-impact confirmation" do
    it "prints no warning when only this service references the accessory" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner, output: output)

      command.stop("postgres").should be_true

      output.to_s.should_not contain("shared by")
      accessory_commands_for(runner, "192.168.1.20").should contain("systemctl --user stop postgres.service")
    end

    it "warns and declines by default when other services share the accessory" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss", "vaultwarden"))
      output = IO::Memory.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner, output: output)

      command.stop("postgres").should be_false

      text = output.to_s
      text.should contain("Accessory 'postgres' is shared by 3 services:")
      text.should contain("freshrss")
      text.should contain("nextcloud")
      text.should contain("vaultwarden")
      text.should contain("Stopping it will affect all of them.")
      text.should contain("Continue? [y/N]")
      text.should contain("Aborted.")
    end

    it "leaves the accessory untouched when the confirmation is declined" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(
        content: shared_postgres_config,
        runner: runner,
        input: IO::Memory.new("n\n")
      )

      command.stop("postgres").should be_false

      accessory_commands_for(runner, "192.168.1.20").should eq([MANIFEST_LIST_COMMAND])
    end

    it "stops when the confirmation is accepted" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(
        content: shared_postgres_config,
        runner: runner,
        input: IO::Memory.new("y\n")
      )

      command.stop("postgres").should be_true

      accessory_commands_for(runner, "192.168.1.20").should contain("systemctl --user stop postgres.service")
    end

    it "bypasses only the shared-impact confirmation with force" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      output = IO::Memory.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner, output: output)

      command.stop("postgres", force: true).should be_true

      output.to_s.should_not contain("Continue?")
      accessory_commands_for(runner, "192.168.1.20").should contain("systemctl --user stop postgres.service")
    end

    it "declines rather than blocking when stdin is not interactive" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(
        content: shared_postgres_config,
        runner: runner,
        input: IO::Memory.new("")
      )

      command.stop("postgres").should be_false
    end
  end

  describe "#remove" do
    it "stops the unit and deletes the Quadlet" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner, output: output)

      command.remove("postgres").should be_true

      accessory_commands_for(runner, "192.168.1.20").should eq([
        MANIFEST_LIST_COMMAND,
        "systemctl --user stop postgres.service",
        "rm -f .config/containers/systemd/postgres.container",
        "systemctl --user daemon-reload",
      ])
      output.to_s.should_not contain("shared by")
    end

    it "never deletes persistent volumes" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.remove("postgres")

      commands = accessory_commands_for(runner, "192.168.1.20")
      commands.any?(&.includes?("volume rm")).should be_false
      commands.any?(&.includes?("postgres-data")).should be_false
    end

    it "never deletes the accessory network" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.remove("postgres")

      accessory_commands_for(runner, "192.168.1.20").any?(&.includes?("network rm")).should be_false
    end

    it "warns and declines by default when other services share the accessory" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss", "vaultwarden"))
      output = IO::Memory.new
      command = build_accessory_command(content: shared_postgres_config, runner: runner, output: output)

      command.remove("postgres").should be_false

      text = output.to_s
      text.should contain("Accessory 'postgres' is shared by 3 services:")
      text.should contain("Removing it will affect all of them.")
      accessory_commands_for(runner, "192.168.1.20").should eq([MANIFEST_LIST_COMMAND])
    end

    it "bypasses the shared-impact confirmation with force" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(manifest_listing("freshrss"))
      command = build_accessory_command(content: shared_postgres_config, runner: runner)

      command.remove("postgres", force: true).should be_true

      accessory_commands_for(runner, "192.168.1.20").should contain(
        "rm -f .config/containers/systemd/postgres.container"
      )
    end
  end

  describe "#logs" do
    it "runs journalctl for the accessory service" do
      streaming_runner = FakeSSHStreamingRunner.new
      command = build_accessory_command(streaming_runner: streaming_runner)

      exit_code = command.logs("db")

      exit_code.should eq(0)
      invocation = streaming_runner.invocations.last
      invocation.host.should eq("192.168.1.20")
      invocation.remote_command.should eq("journalctl --user -u db.service -f --no-pager")
    end
  end
end
