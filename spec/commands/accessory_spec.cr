require "../spec_helper"

def build_accessory_command(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  streaming_runner : FakeSSHStreamingRunner = FakeSSHStreamingRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner, streaming_runner: streaming_runner)
  Meridian::Commands::Accessory.new(config, ssh_executor: executor, output: output, error: output)
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
      input = upload.not_nil!.input || raise "Expected uploaded Quadlet content"
      input.should contain("Image=docker.io/library/postgres:16")
      input.should contain("ContainerName=db")
    end

    it "targets the host defined in the accessory configuration" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      runner.invocations.compact_map(&.host).uniq.should eq(["192.168.1.20"])
    end

    it "runs daemon-reload before starting the accessory" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      accessory_commands_for(runner, "192.168.1.20").should eq([
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
      input = upload.not_nil!.input || raise "Expected uploaded Quadlet content"
      input.should contain("PublishPort=5432:5432")
    end

    it "mounts the configured volume" do
      runner = FakeSSHRunner.new
      command = build_accessory_command(runner: runner)

      command.start("db")

      upload = runner.invocations.find(&.remote_command.==("cat > .config/containers/systemd/db.container"))
      upload.should_not be_nil
      input = upload.not_nil!.input || raise "Expected uploaded Quadlet content"
      input.should contain("Volume=pgdata:/var/lib/postgresql/data")
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
      commands.any?(&.includes?("kamal-proxy")).should be_false
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
