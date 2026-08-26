require "../spec_helper"

private def build_config(
  host : String = "1.2.3.4",
  port : Int32 = 22,
  root_user : String = "root",
  deploy_user : String = "deploy",
  public_key_file : String = "/tmp/meridian_test.pub",
  private_key_file : String = "/tmp/meridian_test",
  accept_new_host_key : Bool = true,
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
      local_path = args.find(&.includes?("meridian-bootstrap"))
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
  FileUtils.rm_rf(value!(private_key))
  FileUtils.rm_rf("#{value!(private_key)}.pub")
end

private def run_bootstrap(config, runner = FakeBootstrapRunner.new)
  Meridian::Server::Bootstrapper.new(config, runner: runner, output: IO::Memory.new).bootstrap
end

private def captured_script(runner : ContentCapturingRunner) : String
  runner.captured_scripts.values.first
end

describe Meridian::Server::Bootstrapper do
  describe "#bootstrap — sequencing" do
    it "uploads the provisioning script before executing it as root" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        scp_idx = all.index { |i| i.command == "scp" }
        ssh_idx = all.index { |i| i.command == "ssh" && i.step.includes?("Provision") }
        scp_idx.should_not be_nil
        ssh_idx.should_not be_nil
        value!(scp_idx).should be < value!(ssh_idx)
      end
    end

    it "uploads exactly one script — bootstrap is a single phase" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        runner.invocations.count(&.command.==("scp")).should eq(1)
        runner.captured_scripts.size.should eq(1)
      end
    end

    it "runs exactly one deploy login check, after provisioning" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        provision_idx = all.index! { |i| i.command == "ssh" && i.step.includes?("Provision") }
        check_idx = all.index! { |i| !i.interactive }

        provision_idx.should be < check_idx
        all.count { |i| !i.interactive }.should eq(1)
      end
    end

    it "creates deploy directories after the deploy login check" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        all = runner.invocations
        check_idx = all.index! { |i| !i.interactive }
        mkdir_idx = all.index! { |i| i.step.includes?("Create deploy directories") }

        check_idx.should be < mkdir_idx
        all[mkdir_idx].args.last.should eq("mkdir -p ~/.config/containers/systemd ~/.local/share/containers")
      end
    end

    it "raises BootstrapError when the deploy login check fails" do
      with_temp_keys do |priv, pub|
        runner = FakeBootstrapRunner.new
        runner.enqueue_check(false)

        expect_raises(Meridian::Server::BootstrapError, /Deploy SSH login test failed/) do
          run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)
        end
      end
    end

    it "cleans up the temp script even when an error is raised" do
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

        deploy_ops = runner.invocations.select(&.args.includes?("BatchMode=yes"))
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

        runner.invocations.all?(&.args.includes?("2222")).should be_true
      end
    end
  end

  describe "#bootstrap — script content" do
    it "contains apt-get install with podman" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        script = captured_script(runner)
        script.should contain("apt-get install")
        script.should contain("podman")
      end
    end

    it "installs no extra transfer packages when transfer mode is nil" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, transfer_mode: nil), runner)

        install_line = captured_script(runner).lines.find!(&.includes?("apt-get install -y"))
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

        install_line = captured_script(runner).lines.find!(&.includes?("apt-get install -y"))
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

        install_line = captured_script(runner).lines.find!(&.includes?("apt-get install -y"))
        install_line.should contain(%("zstd"))
        install_line.should contain(%("rsync"))
        install_line.should contain(%("skopeo"))
      end
    end

    it "embeds the base64-encoded public key" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        expected_b64 = Base64.strict_encode(File.read(pub).strip)
        captured_script(runner).should contain(expected_b64)
      end
    end

    it "prepares rootless podman prerequisites" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        script = captured_script(runner)
        script.should contain("/etc/subuid")
        script.should contain("/etc/subgid")
        script.should contain("loginctl enable-linger")
      end
    end

    it "configures sysctl low ports when rootless_low_ports is true" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, rootless_low_ports: true, rootless_port_start: 80), runner)

        script = captured_script(runner)
        script.should contain("ip_unprivileged_port_start")
        script.should contain("80")
      end
    end

    it "skips sysctl when rootless_low_ports is false" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, rootless_low_ports: false), runner)

        captured_script(runner).should contain("ROOTLESS_LOW_PORTS=\"no\"")
      end
    end

    # Bootstrap deliberately leaves server policy to the admin. These are the
    # opinionated defaults that were removed; they must not creep back in.
    it "touches no firewall, no unattended upgrades, and no sudoers policy" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv, port: 2222), runner)

        script = captured_script(runner)
        script.should_not contain("ufw")
        script.should_not contain("unattended")
        script.should_not contain("Unattended-Upgrade")
        script.should_not contain("NOPASSWD")
        script.should_not contain("sudoers")
      end
    end

    it "does not upgrade the whole system or touch sshd config" do
      with_temp_keys do |priv, pub|
        runner = ContentCapturingRunner.new
        run_bootstrap(build_config(public_key_file: pub, private_key_file: priv), runner)

        script = captured_script(runner)
        script.should_not contain("apt-get -y upgrade")
        script.should_not contain("PermitRootLogin")
        script.should_not contain("PasswordAuthentication")
        script.should_not contain("sshd_config")
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
