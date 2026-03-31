require "../spec_helper"

def build_orchestrator(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Deploy::Orchestrator.new(
    config,
    ssh_executor: executor,
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    output: output
  )
end

describe "Meridian::Deploy::Orchestrator" do
  describe "#deploy_to_host" do
    it "issues a podman pull command" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      invocation = runner.invocations.first
      invocation.command.should eq("ssh")
      invocation.args.should eq(["192.168.1.10", "podman pull registry.example.com/myorg/myapp"])
    end

    it "calls systemctl daemon-reload after writing the Quadlet file" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[4].args.should eq(["192.168.1.10", "systemctl --user daemon-reload"])
    end

    it "starts the new service" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[7].args.should eq(["192.168.1.10", "systemctl --user start myapp-green.service"])
    end

    it "stops the old service before starting the new one" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[6].args.should eq(["192.168.1.10", "systemctl --user stop myapp-green.service"])
      runner.invocations[7].args.should eq(["192.168.1.10", "systemctl --user start myapp-green.service"])
    end

    it "writes the Quadlet file to the correct systemd path" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      network_upload = runner.invocations[2]
      container_upload = runner.invocations[3]
      network_input = network_upload.input || raise "Expected network upload input"
      container_input = container_upload.input || raise "Expected container upload input"

      network_upload.args.should eq(["192.168.1.10", "cat > .config/containers/systemd/myapp.network"])
      network_input.should contain("[Network]")

      container_upload.args.should eq(["192.168.1.10", "cat > .config/containers/systemd/myapp-green.container"])
      container_input.should contain("[Container]")
      container_input.should contain("ContainerName=myapp-green")
    end

    it "raises DeployFailed when the pull command fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "pull failed\n")
      )
      orchestrator = build_orchestrator(runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /exit code 1/) do
        orchestrator.deploy_to_host("192.168.1.10", "web")
      end
    end

    it "raises DeployFailed when systemctl start fails" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "active\n", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: ""),
        Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "start failed\n"),
      )
      orchestrator = build_orchestrator(runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /exit code 1/) do
        orchestrator.deploy_to_host("192.168.1.10", "web")
      end
    end
  end

  describe "#zero_downtime_deploy_to_host" do
    pending "starts the new colour before stopping the old one"
    pending "invokes kamal-proxy deploy before stopping the old container"
    pending "passes the correct target to kamal-proxy deploy"
    pending "runs the health check before switching proxy traffic"
    pending "does not stop the old container if the health check fails"
    pending "writes the active colour to .meridian-color after a successful deploy"
    pending "prunes old images after a successful deploy"
  end

  describe "#deploy" do
    pending "deploys to all hosts in the web role"
    pending "deploys to all hosts in the workers role"
    pending "respects boot.limit by deploying at most that many hosts at once"
    pending "does not deploy workers until at least one web host has passed its health check"
    pending "aborts the entire deploy if all web hosts fail"
    pending "prefixes log output with the host address"
  end
end
