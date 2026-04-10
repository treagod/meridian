require "../spec_helper"

private def build_config(
  host : String = "1.2.3.4",
  port : Int32 = 22,
  root_user : String = "root",
  deploy_user : String = "deploy",
  public_key_file : String = "/tmp/meridian_test.pub",
  private_key_file : String = "/tmp/meridian_test",
  accept_new_host_key : Bool = true,
  enable_auto_updates : Bool = true,
  passwordless_sudo : Bool = true,
  rootless_low_ports : Bool = true,
  rootless_port_start : Int32 = 80,
  transfer_mode : Meridian::Config::TransferMode? = nil,
) : Meridian::Server::BootstrapConfig
  Meridian::Server::BootstrapConfig.new(
    host: host,
    port: port,
    root_user: root_user,
    deploy_user: deploy_user,
    public_key_file: public_key_file,
    private_key_file: private_key_file,
    accept_new_host_key: accept_new_host_key,
    enable_auto_updates: enable_auto_updates,
    passwordless_sudo: passwordless_sudo,
    rootless_low_ports: rootless_low_ports,
    rootless_port_start: rootless_port_start,
    transfer_mode: transfer_mode,
  )
end

# Captures the content of uploaded scripts before they are deleted in ensure.
class ContentCapturingRunner < FakeBootstrapRunner
  getter captured_scripts = {} of String => String

  def run_interactive(command : String, args : Array(String), step : String) : Nil
    if command == "scp"
      local_path = args.find { |a| a.includes?("meridian-bootstrap") }
      if local_path && File.exists?(local_path)
        @captured_scripts[step] = File.read(local_path)
      end
    end
    super
  end
end

private def with_temp_keys(& : String, String ->)
  private_key = File.join(Dir.tempdir, "meridian_test_key_#{Random::Secure.hex(4)}")
  public_key = "#{private_key}.pub"
  File.write(private_key, "FAKE_PRIVATE_KEY")
  File.write(public_key, "ssh-ed25519 AAAAFAKEKEY comment")
  yield private_key, public_key
ensure
  FileUtils.rm_rf(private_key.not_nil!)
  FileUtils.rm_rf("#{private_key.not_nil!}.pub")
end

private def run_bootstrap(config, runner = FakeBootstrapRunner.new)
  Meridian::Server::Bootstrapper.new(config, runner: runner, output: IO::Memory.new).bootstrap
end

describe Meridian::Server::Bootstrapper do
  describe "#bootstrap — sequencing" do
    it "uploads phase 1 script before executing it as root" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        scp_idx = all.index { |i| i.command == "scp" && i.step.includes?("phase1") }
        ssh_idx = all.index { |i| i.command == "ssh" && i.step.includes?("phase 1") }
        scp_idx.should_not be_nil
        ssh_idx.should_not be_nil
        scp_idx.not_nil!.should be < ssh_idx.not_nil!
      end
    end

    it "tests deploy login between phase 1 and phase 2" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        phase1_idx = all.index { |i| i.command == "ssh" && i.step.includes?("phase 1") }.not_nil!
        check1_idx = all.index { |i| !i.interactive }.not_nil!
        phase2_idx = all.index { |i| i.command == "ssh" && i.step.includes?("phase 2") }.not_nil!

        phase1_idx.should be < check1_idx
        check1_idx.should be < phase2_idx
      end
    end

    it "runs a second deploy login check after phase 2" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        runner.invocations.count { |i| !i.interactive }.should eq(2)
      end
    end

    it "creates deploy directories after the first deploy login check and before phase 2" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        check1_idx = all.index { |i| !i.interactive }.not_nil!
        mkdir_idx = all.index { |i| i.step.includes?("Create deploy directories") }.not_nil!
        phase2_idx = all.index { |i| i.command == "ssh" && i.step.includes?("phase 2") }.not_nil!

        check1_idx.should be < mkdir_idx
        mkdir_idx.should be < phase2_idx
        all[mkdir_idx].args.last.should eq("mkdir -p ~/.config/containers/systemd ~/.local/share/containers")
      end
    end

    it "uses deploy+sudo for phase 2 when passwordless_sudo is true" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, passwordless_sudo: true), runner)

        phase2_scp = runner.invocations.find { |i| i.command == "scp" && i.step.includes?("phase2") }
        phase2_scp.not_nil!.args.should contain("BatchMode=yes")

        phase2_ssh = runner.invocations.find { |i| i.command == "ssh" && i.step.includes?("phase 2") }
        phase2_ssh.not_nil!.args.last.should contain("sudo -n bash")
      end
    end

    it "uses root for phase 2 when passwordless_sudo is false" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, passwordless_sudo: false), runner)

        phase2_ssh = runner.invocations.find { |i| i.command == "ssh" && i.step.includes?("phase 2") }
        phase2_ssh.not_nil!.args.should contain("PubkeyAuthentication=no")
        phase2_ssh.not_nil!.args.last.should_not contain("sudo")
      end
    end

    it "raises BootstrapError when first deploy login check fails" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        runner.enqueue_check(false)

        expect_raises(Meridian::Server::BootstrapError, /Deploy SSH login test failed/) do
          run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)
        end
      end
    end

    it "raises BootstrapError when final deploy login check fails" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        runner.enqueue_check(true)
        runner.enqueue_check(false)

        expect_raises(Meridian::Server::BootstrapError, /Final deploy SSH login test failed/) do
          run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)
        end
      end
    end

    it "cleans up temp scripts even when an error is raised" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        runner.enqueue_check(false)

        before = Dir.glob(File.join(Dir.tempdir, "meridian-bootstrap-*")).to_set

        expect_raises(Meridian::Server::BootstrapError) do
          run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)
        end

        after = Dir.glob(File.join(Dir.tempdir, "meridian-bootstrap-*")).to_set
        (after - before).should be_empty
      end
    end
  end

  describe "#bootstrap — SSH options" do
    it "uses PreferredAuthentications=password and PubkeyAuthentication=no for root SSH and SCP" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        root_ops = runner.invocations.select { |i| i.args.includes?("PubkeyAuthentication=no") }
        root_ops.should_not be_empty
        root_ops.all? { |i| i.args.includes?("PreferredAuthentications=password,keyboard-interactive") }.should be_true
        root_ops.any? { |i| i.command == "scp" }.should be_true
        root_ops.any? { |i| i.command == "ssh" }.should be_true
      end
    end

    it "uses identity file and BatchMode for deploy SSH operations" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        deploy_ops = runner.invocations.select { |i| i.args.includes?("BatchMode=yes") }
        deploy_ops.should_not be_empty
        deploy_ops.all? { |i| i.args.includes?("-i") && i.args.includes?(priv) }.should be_true
      end
    end

    it "uses StrictHostKeyChecking=yes when accept_new_host_key is false" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, accept_new_host_key: false), runner)

        runner.invocations.all? { |i| i.args.includes?("StrictHostKeyChecking=yes") }.should be_true
      end
    end

    it "uses StrictHostKeyChecking=accept-new when accept_new_host_key is true" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, accept_new_host_key: true), runner)

        runner.invocations.all? { |i| i.args.includes?("StrictHostKeyChecking=accept-new") }.should be_true
      end
    end

    it "includes the configured port in all SSH and SCP invocations" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, port: 2222), runner)

        runner.invocations.all? { |i| i.args.includes?("2222") }.should be_true
      end
    end
  end

  describe "#bootstrap — script content" do
    it "phase 1 script contains apt-get install with podman" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.should_not be_nil
        phase1.not_nil!.should contain("apt-get install")
        phase1.not_nil!.should contain("podman")
      end
    end

    it "installs ufw without extra transfer packages when transfer mode is nil" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, transfer_mode: nil), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1]).not_nil!
        install_line = phase1.lines.find(&.includes?("apt-get install -y")).not_nil!
        install_line.should contain(%("ufw"))
        install_line.should_not contain(%("zstd"))
        install_line.should_not contain(%("rsync"))
        install_line.should_not contain(%("skopeo"))
      end
    end

    it "installs zstd for stream transfer mode" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(
          build_config(
            public_key_file: pub,
            private_key_file: priv,
            transfer_mode: Meridian::Config::TransferMode::Stream
          ),
          runner
        )

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1]).not_nil!
        install_line = phase1.lines.find(&.includes?("apt-get install -y")).not_nil!
        install_line.should contain(%("ufw"))
        install_line.should contain(%("zstd"))
        install_line.should_not contain(%("rsync"))
        install_line.should_not contain(%("skopeo"))
      end
    end

    it "installs zstd, rsync, and skopeo for incremental transfer mode" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(
          build_config(
            public_key_file: pub,
            private_key_file: priv,
            transfer_mode: Meridian::Config::TransferMode::Incremental
          ),
          runner
        )

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1]).not_nil!
        install_line = phase1.lines.find(&.includes?("apt-get install -y")).not_nil!
        install_line.should contain(%("ufw"))
        install_line.should contain(%("zstd"))
        install_line.should contain(%("rsync"))
        install_line.should contain(%("skopeo"))
      end
    end

    it "phase 1 script embeds the base64-encoded public key" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        pub_content = File.read(pub).strip
        expected_b64 = Base64.strict_encode(pub_content)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.not_nil!.should contain(expected_b64)
      end
    end

    it "phase 1 script includes passwordless sudo when passwordless_sudo is true" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, passwordless_sudo: true), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.not_nil!.should contain("NOPASSWD:ALL")
      end
    end

    it "sets PASSWORDLESS_SUDO=no in phase 1 script when passwordless_sudo is false" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, passwordless_sudo: false), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.not_nil!.should contain("PASSWORDLESS_SUDO=\"no\"")
      end
    end

    it "phase 1 script configures sysctl low ports when rootless_low_ports is true" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, rootless_low_ports: true, rootless_port_start: 80), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.not_nil!.should contain("ip_unprivileged_port_start")
        phase1.not_nil!.should contain("80")
      end
    end

    it "phase 1 script skips sysctl when rootless_low_ports is false" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, rootless_low_ports: false), runner)

        # ROOTLESS_LOW_PORTS=no, script only sets sysctl when it equals "yes"
        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1])
        phase1.not_nil!.should contain("ROOTLESS_LOW_PORTS=\"no\"")
      end
    end

    it "phase 1 script opens SSH, HTTP, and HTTPS in ufw and enables it" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, port: 2222), runner)

        phase1 = runner.captured_scripts.find { |k, _| k.includes?("phase1") }.try(&.[1]).not_nil!
        phase1.should contain("ufw allow 2222/tcp")
        phase1.should contain("ufw allow 80/tcp")
        phase1.should contain("ufw allow 443/tcp")
        phase1.should contain("ufw --force enable")
      end
    end

    it "phase 2 script disables root SSH login and password authentication" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        phase2 = runner.captured_scripts.find { |k, _| k.includes?("phase2") }.try(&.[1])
        phase2.should_not be_nil
        phase2.not_nil!.should contain("PermitRootLogin no")
        phase2.not_nil!.should contain("PasswordAuthentication no")
      end
    end
  end

  describe "validation" do
    it "raises BootstrapError when public key file is empty" do
      with_tempdir do |dir|
        pub = File.join(dir, "test.pub")
        priv = File.join(dir, "test")
        File.write(pub, "")
        File.write(priv, "FAKE")

        expect_raises(Meridian::Server::BootstrapError, /empty/) do
          run_bootstrap(build_config(public_key_file: pub, private_key_file: priv))
        end
      end
    end
  end
end
