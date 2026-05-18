require "../spec_helper"

private def build_server_command(
  content : String = FULL_CONFIG_WITH_KEYS,
  runner : FakeBootstrapRunner = FakeBootstrapRunner.new,
  output : IO = IO::Memory.new,
) : Meridian::Commands::Server
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: FakeSSHRunner.new)
  Meridian::Commands::Server.new(
    config,
    ssh_executor: executor,
    output: output,
    error: output,
    bootstrap_runner: runner,
  )
end

class ServerContentCapturingRunner < FakeBootstrapRunner
  getter captured_scripts = {} of String => String

  def run_interactive(command : String, args : Array(String), step : String) : Nil
    if command == "scp"
      local_path = args.find { |arg| arg.includes?("meridian-bootstrap") }
      if local_path && File.exists?(local_path)
        @captured_scripts[step] = File.read(local_path)
      end
    end

    super
  end
end

private def make_invocation(
  host : String? = "1.2.3.4",
  port : Int32? = nil,
  root_user : String = "root",
  deploy_user : String? = nil,
  accept_new_host_key : Bool = true,
  enable_auto_updates : Bool = true,
  passwordless_sudo : Bool = true,
  rootless_low_ports : Bool = true,
  rootless_port_start : Int32 = 80,
  file : String = "deploy.yml",
) : Meridian::CLI::ServerBootstrapInvocation
  Meridian::CLI::ServerBootstrapInvocation.new(
    host: host,
    port: port,
    root_user: root_user,
    deploy_user: deploy_user,
    accept_new_host_key: accept_new_host_key,
    enable_auto_updates: enable_auto_updates,
    passwordless_sudo: passwordless_sudo,
    rootless_low_ports: rootless_low_ports,
    rootless_port_start: rootless_port_start,
    file: file,
  )
end

describe Meridian::Commands::Server do
  describe "#bootstrap" do
    it "uses config ssh.user as deploy_user when invocation deploy_user is nil" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.2.3.4
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: customdeploy
            port: 22
            keys:
              - #{priv}
          YAML

        runner = FakeBootstrapRunner.new
        command = build_server_command(content: config_yaml, runner: runner)
        command.bootstrap(make_invocation(host: "1.2.3.4", deploy_user: nil))

        deploy_op = runner.invocations.find { |i| i.args.includes?("BatchMode=yes") }
        deploy_op.not_nil!.args.any?(&.includes?("customdeploy@")).should be_true
      end
    end

    it "uses invocation deploy_user when provided, overriding config" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.2.3.4
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: defaultuser
            port: 22
            keys:
              - #{priv}
          YAML

        runner = FakeBootstrapRunner.new
        command = build_server_command(content: config_yaml, runner: runner)
        command.bootstrap(make_invocation(host: "1.2.3.4", deploy_user: "myuser"))

        deploy_op = runner.invocations.find { |i| i.args.includes?("BatchMode=yes") }
        deploy_op.not_nil!.args.any?(&.includes?("myuser@")).should be_true
      end
    end

    it "uses config ssh.port as port when invocation port is nil" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.2.3.4
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: deploy
            port: 2222
            keys:
              - #{priv}
          YAML

        runner = FakeBootstrapRunner.new
        command = build_server_command(content: config_yaml, runner: runner)
        command.bootstrap(make_invocation(host: "1.2.3.4", port: nil))

        runner.invocations.all? { |i| i.args.includes?("2222") }.should be_true
      end
    end

    it "expands home-relative ssh key paths before bootstrapping" do
      with_tempdir do |home|
        old_home = ENV["HOME"]?
        ENV["HOME"] = home
        begin
          ssh_dir = File.join(home, ".ssh")
          Dir.mkdir_p(ssh_dir)
          priv = File.join(ssh_dir, "id_ed25519")
          pub = "#{priv}.pub"
          File.write(priv, "FAKE")
          File.write(pub, "ssh-ed25519 AAAAFAKE comment")

          config_yaml = <<-YAML
            service: myapp
            image: registry.example.com/myorg/myapp
            servers:
              web:
                hosts:
                  - 1.2.3.4
            proxy:
              image: ghcr.io/basecamp/kamal-proxy:latest
            registry:
              server: registry.example.com
              username: deploy
              password:
                - REGISTRY_PASSWORD
            ssh:
              user: deploy
              port: 22
              keys:
                - ~/.ssh/id_ed25519
            YAML

          runner = FakeBootstrapRunner.new
          command = build_server_command(content: config_yaml, runner: runner)
          command.bootstrap(make_invocation(host: "1.2.3.4"))

          deploy_op = runner.invocations.find { |i| i.args.includes?("BatchMode=yes") }
          deploy_op.not_nil!.args.should contain(priv)
        ensure
          if old_home
            ENV["HOME"] = old_home
          else
            ENV.delete("HOME")
          end
        end
      end
    end

    it "raises BootstrapError when ssh.keys is empty" do
      config_yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp
        servers:
          web:
            hosts:
              - 1.2.3.4
        proxy:
          image: ghcr.io/basecamp/kamal-proxy:latest
        registry:
          server: registry.example.com
          username: deploy
          password:
            - REGISTRY_PASSWORD
        YAML

      command = build_server_command(content: config_yaml)
      expect_raises(Meridian::Server::BootstrapError, /No SSH keys/) do
        command.bootstrap(make_invocation)
      end
    end

    it "infers host from deploy.yml when --host is omitted and only one host is configured" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 5.6.7.8
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: deploy
            port: 22
            keys:
              - #{priv}
          YAML

        runner = FakeBootstrapRunner.new
        command = build_server_command(content: config_yaml, runner: runner)
        command.bootstrap(make_invocation(host: nil))

        runner.invocations.any? { |i| i.args.any?(&.includes?("5.6.7.8")) }.should be_true
      end
    end

    it "raises BootstrapError when --host is omitted and multiple hosts are configured" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.1.1.1
                - 2.2.2.2
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: deploy
            port: 22
            keys:
              - #{priv}
          YAML

        command = build_server_command(content: config_yaml)
        expect_raises(Meridian::Server::BootstrapError, /Multiple hosts/) do
          command.bootstrap(make_invocation(host: nil))
        end
      end
    end

    it "raises BootstrapError when derived public key file does not exist" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        File.write(priv, "FAKE")
        # intentionally NOT writing the .pub file

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.2.3.4
          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
          registry:
            server: registry.example.com
            username: deploy
            password:
              - REGISTRY_PASSWORD
          ssh:
            user: deploy
            port: 22
            keys:
              - #{priv}
          YAML

        command = build_server_command(content: config_yaml)
        expect_raises(Meridian::Server::BootstrapError, /Public key file not found/) do
          command.bootstrap(make_invocation)
        end
      end
    end

    it "threads transfer.mode into bootstrap package selection" do
      with_tempdir do |dir|
        priv = File.join(dir, "id_ed25519")
        pub = "#{priv}.pub"
        File.write(priv, "FAKE")
        File.write(pub, "ssh-ed25519 AAAAFAKE comment")

        config_yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp
          servers:
            web:
              hosts:
                - 1.2.3.4
          transfer:
            mode: incremental
          ssh:
            user: deploy
            port: 22
            keys:
              - #{priv}
          YAML

        runner = ServerContentCapturingRunner.new
        command = build_server_command(content: config_yaml, runner: runner)
        command.bootstrap(make_invocation)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1]).not_nil!
        install_line = phase1.lines.find(&.includes?("apt-get install -y")).not_nil!
        install_line.should contain(%("zstd"))
        install_line.should contain(%("rsync"))
        install_line.should contain(%("skopeo"))
      end
    end
  end
end
