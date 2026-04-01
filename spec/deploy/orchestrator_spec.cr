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

def ssh_ok(stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: 0, stdout: stdout, stderr: stderr)
end

def ssh_fail(exit_code : Int32 = 1, stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr)
end

def enqueue_zero_downtime_success(
  runner : FakeSSHRunner,
  *,
  marker : String? = nil,
  blue_active : Bool = false,
  green_active : Bool = false,
  old_active : Bool? = nil,
  container_ip : String = "10.88.0.12",
  health_status : String = "200",
  prune_result : Meridian::SSH::Result = ssh_ok,
)
  results = [] of Meridian::SSH::Result

  if stored_marker = marker
    results << ssh_ok("#{stored_marker}\n")
    resolved_old_active = old_active.nil? ? true : old_active
    results << (resolved_old_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))
  else
    results << ssh_fail(1, "", "No such file\n")
    results << (blue_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))
    results << (green_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))

    current_color_active =
      if blue_active
        blue_active
      elsif green_active
        green_active
      else
        old_active || false
      end
    results << (current_color_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))
  end

  results.concat([
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok("#{container_ip}\n"),
    ssh_ok(health_status),
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    prune_result,
  ])

  results.each do |result|
    runner.enqueue_results(result)
  end
end

def enqueue_zero_downtime_health_failure(
  runner : FakeSSHRunner,
  *,
  marker : String? = nil,
  blue_active : Bool = false,
  green_active : Bool = false,
  container_ip : String = "10.88.0.12",
  health_result : Meridian::SSH::Result = ssh_ok("500"),
)
  results = [] of Meridian::SSH::Result

  if stored_marker = marker
    results << ssh_ok("#{stored_marker}\n")
    results << ssh_ok("active\n")
  else
    results << ssh_fail(1, "", "No such file\n")
    results << (blue_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))
    results << (green_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))

    current_color_active = blue_active || green_active
    results << (current_color_active ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"))
  end

  results.concat([
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok("#{container_ip}\n"),
  ])

  10.times do
    results << health_result
  end

  results.concat([
    ssh_ok,
    ssh_ok,
    ssh_ok,
  ])

  results.each do |result|
    runner.enqueue_results(result)
  end
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
    it "starts the new colour before stopping the old one" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = runner.invocations.map(&.args[1])
      start_index = commands.index("systemctl --user start myapp-blue.service") || raise "Expected new service start"
      stop_index = commands.index("systemctl --user stop myapp-green.service") || raise "Expected old service stop"

      start_index.should be < stop_index
    end

    it "invokes kamal-proxy deploy before stopping the old container" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = runner.invocations.map(&.args[1])
      deploy_index = commands.index("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-blue:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls") || raise "Expected proxy deploy command"
      stop_index = commands.index("systemctl --user stop myapp-green.service") || raise "Expected old service stop"

      deploy_index.should be < stop_index
    end

    it "passes the correct target and proxy flags to kamal-proxy deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      invocation = runner.invocations.find do |candidate|
        candidate.args[1].starts_with?("podman exec kamal-proxy kamal-proxy deploy")
      end || raise "Expected proxy deploy invocation"

      invocation.args.should eq([
        "192.168.1.10",
        "podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-blue:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls",
      ])
    end

    it "runs the health check before switching proxy traffic" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true, container_ip: "10.88.0.12")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = runner.invocations.map(&.args[1])
      health_index = commands.index("curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 5.0 --max-time 5.0 http://10.88.0.12:3000/health") || raise "Expected health check invocation"
      deploy_index = commands.index("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-blue:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls") || raise "Expected proxy deploy invocation"

      health_index.should be < deploy_index
    end

    it "does not stop the old container if the health check fails" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_health_failure(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /status 500/) do
        orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")
      end

      commands = runner.invocations.map(&.args[1])
      commands.should_not contain("systemctl --user stop myapp-green.service")
      commands.should contain("systemctl --user stop myapp-blue.service")
      commands.should contain("rm -f .config/containers/systemd/myapp-blue.container")
    end

    it "writes the active colour to .meridian-color after a successful deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      marker_upload = runner.invocations.find do |candidate|
        candidate.args[1] == "cat > .config/containers/systemd/.meridian-color"
      end || raise "Expected active color upload"

      marker_upload.input.should eq("blue\n")
    end

    it "removes the old Quadlet file after a successful deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      runner.invocations.map(&.args[1]).should contain("rm -f .config/containers/systemd/myapp-green.container")
    end

    it "prunes old images after a successful deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      runner.invocations.map(&.args[1]).should contain("podman image prune -f")
    end

    it "uses the stored marker when .meridian-color is present" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, marker: "green")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = runner.invocations.map(&.args[1])
      commands.first.should eq("cat .config/containers/systemd/.meridian-color")
      commands.should contain("systemctl --user start myapp-blue.service")
      commands.count("systemctl --user is-active myapp-blue.service").should eq(0)
      commands.count("systemctl --user is-active myapp-green.service").should eq(1)
    end

    it "auto-detects the existing green service when the marker is missing" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      runner.invocations.map(&.args[1]).should contain("systemctl --user start myapp-blue.service")
    end

    it "starts with green when neither colour is active and the marker is missing" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = runner.invocations.map(&.args[1])
      commands.should contain("systemctl --user start myapp-green.service")
      commands.should_not contain("systemctl --user stop myapp-blue.service")
      commands.should contain("rm -f .config/containers/systemd/myapp-blue.container")
    end

    it "raises DeployFailed when both colours are active and the marker is missing" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        ssh_fail(1, "", "No such file\n"),
        ssh_ok("active\n"),
        ssh_ok("active\n"),
      )
      orchestrator = build_orchestrator(runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /both colors are active/) do
        orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")
      end
    end
  end

  describe "#deploy" do
    it "uses the zero-downtime path for web roles with proxy config" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy

      runner.invocations.map(&.args[1]).should contain("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-green:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
    end

    it "falls back to the downtime path when proxy config is absent" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(
        content: <<-YAML,
            service: myapp
            image: registry.example.com/myorg/myapp

            servers:
              web:
                hosts:
                  - 192.168.1.10
        YAML
        runner: runner
      )

      orchestrator.deploy

      commands = runner.invocations.map(&.args[1])
      commands.should contain("systemctl --user start myapp-green.service")
      commands.should_not contain("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-green:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
    end

    pending "deploys to all hosts in the web role"
    pending "deploys to all hosts in the workers role"
    pending "respects boot.limit by deploying at most that many hosts at once"
    pending "does not deploy workers until at least one web host has passed its health check"
    pending "aborts the entire deploy if all web hosts fail"
    pending "prefixes log output with the host address"
  end
end
