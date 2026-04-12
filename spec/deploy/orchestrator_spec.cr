require "../spec_helper"

def build_orchestrator(
  content : String = FULL_CONFIG,
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  stream_transfer : Meridian::Transfer::Stream? = nil,
  incremental_transfer : Meridian::Transfer::Incremental? = nil,
  batch_sleeper : Proc(Time::Span, Nil) = ->(_duration : Time::Span) { nil },
)
  config = load_config(content)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Deploy::Orchestrator.new(
    config,
    ssh_executor: executor,
    quadlet_generator: Meridian::Quadlet::Generator.new(config),
    stream_transfer: stream_transfer,
    incremental_transfer: incremental_transfer,
    output: output,
    batch_sleeper: batch_sleeper
  )
end

def build_stream_transfer(
  runner : FakeSSHRunner = FakeSSHRunner.new,
  output : IO = IO::Memory.new,
  user : String? = "deploy",
  port : Int32? = nil,
  identity_file : String? = nil,
  local_dependency_checker : Meridian::Transfer::Stream::DependencyChecker = ->(_command : String) { true },
  monotonic_clock : Meridian::Transfer::Stream::MonotonicClock = -> { Time.instant },
  pipeline_runner : Meridian::Transfer::Stream::PipelineRunner = ->(_request : Meridian::Transfer::Stream::PipelineRequest) { Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 256_i64) },
)
  Meridian::Transfer::Stream.new(
    Meridian::SSH::Executor.new(runner: runner),
    output: output,
    user: user,
    port: port,
    identity_file: identity_file,
    local_dependency_checker: local_dependency_checker,
    monotonic_clock: monotonic_clock,
    pipeline_runner: pipeline_runner
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

def enqueue_zero_downtime_success_for_host(
  runner : FakeSSHRunner,
  host : String,
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

  runner.enqueue_results_for_host(host, results)
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

def enqueue_zero_downtime_health_failure_for_host(
  runner : FakeSSHRunner,
  host : String,
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

  runner.enqueue_results_for_host(host, results)
end

def enqueue_deploy_success_for_host(
  runner : FakeSSHRunner,
  host : String,
  *,
  active_service : Bool = false,
)
  runner.enqueue_results_for_host(
    host,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    ssh_ok,
    active_service ? ssh_ok("active\n") : ssh_fail(3, "inactive\n"),
    ssh_ok,
  )
end

def multi_host_config(boot_limit : Int32 = 1, boot_wait : Int32 = 10) : String
  FULL_CONFIG
    .sub("limit: 1", "limit: #{boot_limit}")
    .sub("wait: 10", "wait: #{boot_wait}")
end

def run_deploy_async(orchestrator : Meridian::Deploy::Orchestrator) : Channel(Exception?)
  finished = Channel(Exception?).new

  spawn do
    begin
      orchestrator.deploy
      finished.send(nil)
    rescue ex : Exception
      finished.send(ex)
    end
  end

  finished
end

describe "Meridian::Deploy::Orchestrator" do
  describe "#deploy_to_host" do
    it "issues a podman pull command" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      invocation = runner.invocations.first
      invocation.command.should eq("ssh")
      invocation.host.should eq("192.168.1.10")
      invocation.remote_command.should eq("podman pull registry.example.com/myorg/myapp")
    end

    it "calls systemctl daemon-reload after writing the Quadlet file" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[4].remote_command.should eq("systemctl --user daemon-reload")
    end

    it "starts the new service" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[7].remote_command.should eq("systemctl --user start myapp-green.service")
    end

    it "stops the old service before starting the new one" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations[6].remote_command.should eq("systemctl --user stop myapp-green.service")
      runner.invocations[7].remote_command.should eq("systemctl --user start myapp-green.service")
    end

    it "writes the Quadlet file to the correct systemd path" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy_to_host("192.168.1.10", "web")

      network_upload = runner.invocations[2]
      container_upload = runner.invocations[3]
      network_input = network_upload.input || raise "Expected network upload input"
      container_input = container_upload.input || raise "Expected container upload input"

      network_upload.host.should eq("192.168.1.10")
      network_upload.remote_command.should eq("cat > .config/containers/systemd/myapp.network")
      network_input.should contain("[Network]")

      container_upload.host.should eq("192.168.1.10")
      container_upload.remote_command.should eq("cat > .config/containers/systemd/myapp-green.container")
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

    it "uses configured SSH user, port, and first key for deploy commands" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(
        content: <<-YAML,
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          ssh:
            user: deployer
            port: 2222
            keys:
              - /tmp/id_ed25519
          YAML
        runner: runner
      )

      orchestrator.deploy_to_host("192.168.1.10", "web")

      runner.invocations.first.args.should eq([
        "-p",
        "2222",
        "-i",
        "/tmp/id_ed25519",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=3",
        "deployer@192.168.1.10",
        "podman pull registry.example.com/myorg/myapp",
      ])
    end

    it "uses stream transfer instead of podman pull when transfer mode is stream" do
      runner = FakeSSHRunner.new
      requests = [] of Meridian::Transfer::Stream::PipelineRequest
      stream_transfer = build_stream_transfer(
        runner: runner,
        pipeline_runner: ->(request : Meridian::Transfer::Stream::PipelineRequest) do
          requests << request
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 512_i64)
        end
      )
      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_fail(3, "inactive\n"),
        ssh_ok,
      )
      orchestrator = build_orchestrator(
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
        stream_transfer: stream_transfer
      )

      orchestrator.deploy_to_host("192.168.1.10", "web")

      remote_commands_for(runner, "192.168.1.10").should_not contain("podman pull registry.example.com/myorg/myapp")
      requests.size.should eq(1)
    end

    it "aborts before writing Quadlets when stream transfer fails" do
      runner = FakeSSHRunner.new
      stream_transfer = build_stream_transfer(
        runner: runner,
        pipeline_runner: ->(_request : Meridian::Transfer::Stream::PipelineRequest) do
          raise Meridian::Transfer::TransferFailed.new("ssh failed with exit code 1: boom")
        end
      )
      runner.enqueue_results_for_host("192.168.1.10", ssh_ok)
      orchestrator = build_orchestrator(
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
        stream_transfer: stream_transfer
      )

      expect_raises(Meridian::Deploy::DeployFailed, /ssh failed with exit code 1/) do
        orchestrator.deploy_to_host("192.168.1.10", "web")
      end

      commands = remote_commands_for(runner, "192.168.1.10")
      commands.should eq(["sh -lc 'command -v zstd >/dev/null'"])
    end

    it "uses incremental transfer instead of podman pull when transfer mode is incremental" do
      runner = FakeSSHRunner.new
      incremental_transfer = FakeIncrementalTransfer.new
      orchestrator = build_orchestrator(
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
        runner: runner,
        incremental_transfer: incremental_transfer
      )

      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_fail(3, "inactive\n"),
        ssh_ok,
      )

      orchestrator.deploy_to_host("192.168.1.10", "web")

      remote_commands_for(runner, "192.168.1.10").should_not contain("podman pull registry.example.com/myorg/myapp")
      incremental_transfer.transfer_calls.should eq([
        {host: "192.168.1.10", image: "registry.example.com/myorg/myapp"},
      ])
    end

    it "aborts before writing Quadlets when incremental transfer fails" do
      runner = FakeSSHRunner.new
      incremental_transfer = FakeIncrementalTransfer.new(
        Meridian::Transfer::TransferFailed.new("rsync failed with exit code 12: broken pipe")
      )
      orchestrator = build_orchestrator(
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
        runner: runner,
        incremental_transfer: incremental_transfer
      )

      expect_raises(Meridian::Deploy::DeployFailed, /rsync failed with exit code 12/) do
        orchestrator.deploy_to_host("192.168.1.10", "web")
      end

      runner.invocations.should be_empty
    end
  end

  describe "#zero_downtime_deploy_to_host" do
    it "starts the new colour before stopping the old one" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = remote_commands_for(runner)
      start_index = commands.index("systemctl --user start myapp-blue.service") || raise "Expected new service start"
      stop_index = commands.index("systemctl --user stop myapp-green.service") || raise "Expected old service stop"

      start_index.should be < stop_index
    end

    it "invokes kamal-proxy deploy before stopping the old container" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = remote_commands_for(runner)
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
        candidate.remote_command.try(&.starts_with?("podman exec kamal-proxy kamal-proxy deploy"))
      end || raise "Expected proxy deploy invocation"

      invocation.host.should eq("192.168.1.10")
      invocation.remote_command.should eq("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-blue:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
    end

    it "runs the health check before switching proxy traffic" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true, container_ip: "10.88.0.12")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = remote_commands_for(runner)
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

      commands = remote_commands_for(runner)
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
        candidate.remote_command == "cat > .config/containers/systemd/.meridian-color"
      end || raise "Expected active color upload"

      marker_upload.input.should eq("blue\n")
    end

    it "removes the old Quadlet file after a successful deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      remote_commands_for(runner).should contain("rm -f .config/containers/systemd/myapp-green.container")
    end

    it "prunes old images after a successful deploy" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, green_active: true)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      remote_commands_for(runner).should contain("podman image prune -f")
    end

    it "uses the stored marker when .meridian-color is present" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner, marker: "green")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = remote_commands_for(runner)
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

      remote_commands_for(runner).should contain("systemctl --user start myapp-blue.service")
    end

    it "starts with green when neither colour is active and the marker is missing" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success(runner)
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      commands = remote_commands_for(runner)
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

    it "uses stream transfer instead of podman pull on the zero-downtime path" do
      runner = FakeSSHRunner.new
      requests = [] of Meridian::Transfer::Stream::PipelineRequest
      stream_transfer = build_stream_transfer(
        runner: runner,
        pipeline_runner: ->(request : Meridian::Transfer::Stream::PipelineRequest) do
          requests << request
          Meridian::Transfer::Stream::PipelineResult.new(bytes_transferred: 1024_i64)
        end
      )
      runner.enqueue_results_for_host(
        "192.168.1.10",
        ssh_fail(1, "", "No such file\n"),
        ssh_fail(3, "inactive\n"),
        ssh_ok("active\n"),
        ssh_ok("active\n"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok("10.88.0.12\n"),
        ssh_ok("200"),
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
        ssh_ok,
      )
      orchestrator = build_orchestrator(
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

          transfer:
            mode: stream
          YAML
        runner: runner,
        stream_transfer: stream_transfer
      )

      orchestrator.zero_downtime_deploy_to_host("192.168.1.10", "web")

      remote_commands_for(runner, "192.168.1.10").should_not contain("podman pull registry.example.com/myorg/myapp")
      requests.size.should eq(1)
    end
  end

  describe "#deploy" do
    it "uses the zero-downtime path for web roles with proxy config" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy

      remote_commands_for(runner, "192.168.1.10").should contain("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-green:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
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

      commands = remote_commands_for(runner)
      commands.should contain("systemctl --user start myapp-green.service")
      commands.should_not contain("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-green:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
    end

    it "deploys to all hosts in the web role" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy

      web_1_commands = remote_commands_for(runner, "192.168.1.10")
      web_2_commands = remote_commands_for(runner, "192.168.1.11")

      web_1_commands.any?(&.starts_with?("podman exec kamal-proxy kamal-proxy deploy myapp --target")).should be_true
      web_2_commands.any?(&.starts_with?("podman exec kamal-proxy kamal-proxy deploy myapp --target")).should be_true
    end

    it "deploys to all hosts in the workers role" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner)

      orchestrator.deploy

      worker_commands = remote_commands_for(runner, "192.168.1.12")
      worker_commands.should contain("systemctl --user start myapp-green.service")
      worker_commands.should_not contain("podman exec kamal-proxy kamal-proxy deploy myapp --target myapp-green:3000 --health-check-path /health --health-check-interval 2s --health-check-timeout 5s --host myapp.example.com --tls")
    end

    it "respects boot.limit by deploying at most that many hosts at once" do
      runner = FakeSSHRunner.new
      first_web_release = runner.pause_next_invocation("192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner)

      finished = run_deploy_async(orchestrator)

      first_invocation = runner.invocation_events.receive
      first_invocation.host.should eq("192.168.1.10")
      runner.invocations.map { |invocation| invocation.host || "" }.should eq(["192.168.1.10"])

      first_web_release.send(nil)
      finished.receive.should be_nil
    end

    it "does not deploy workers until at least one web host has passed its health check" do
      runner = FakeSSHRunner.new
      second_web_release = runner.pause_next_invocation("192.168.1.11")
      worker_release = runner.pause_next_invocation("192.168.1.12")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner)

      finished = run_deploy_async(orchestrator)

      seen_blocked_hosts = [] of String
      until seen_blocked_hosts.size == 2
        invocation = runner.invocation_events.receive
        host = invocation.host || raise "Expected host argument"
        if ["192.168.1.11", "192.168.1.12"].includes?(host)
          seen_blocked_hosts << host unless seen_blocked_hosts.includes?(host)
        end
      end

      seen_blocked_hosts.should contain("192.168.1.11")
      seen_blocked_hosts.should contain("192.168.1.12")

      second_web_release.send(nil)
      worker_release.send(nil)
      finished.receive.should be_nil
    end

    it "aborts the entire deploy if all web hosts fail" do
      runner = FakeSSHRunner.new
      enqueue_zero_downtime_health_failure_for_host(runner, "192.168.1.10", health_result: ssh_ok("500"))
      enqueue_zero_downtime_health_failure_for_host(runner, "192.168.1.11", health_result: ssh_ok("500"))
      orchestrator = build_orchestrator(content: multi_host_config(boot_limit: 2), runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /status 500/) do
        orchestrator.deploy
      end

      runner.invocations.none? { |invocation| invocation.host == "192.168.1.12" }.should be_true
    end

    it "prefixes log output with the host address" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10", container_ip: "10.88.0.12")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11", container_ip: "10.88.0.13")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner, output: output)

      orchestrator.deploy

      log_output = output.to_s
      log_output.should contain("[192.168.1.10] Pulling image registry.example.com/myorg/myapp")
      log_output.should contain("[192.168.1.10] Health check attempt 1/10: http://10.88.0.12:3000/health")
      log_output.should contain("[192.168.1.10] Health check passed: http://10.88.0.12:3000/health")
    end

    it "sleeps between successful batches but not after the final batch" do
      runner = FakeSSHRunner.new
      sleeps = [] of Time::Span
      sleeper = ->(duration : Time::Span) { sleeps << duration }
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.10")
      enqueue_zero_downtime_success_for_host(runner, "192.168.1.11")
      enqueue_deploy_success_for_host(runner, "192.168.1.12")
      orchestrator = build_orchestrator(runner: runner, batch_sleeper: sleeper)

      orchestrator.deploy

      sleeps.should eq([10.seconds])
    end

    it "does not sleep after a failing batch" do
      runner = FakeSSHRunner.new
      sleeps = [] of Time::Span
      sleeper = ->(duration : Time::Span) { sleeps << duration }
      enqueue_zero_downtime_health_failure_for_host(runner, "192.168.1.10", health_result: ssh_ok("500"))
      enqueue_zero_downtime_health_failure_for_host(runner, "192.168.1.11", health_result: ssh_ok("500"))
      orchestrator = build_orchestrator(content: multi_host_config(boot_limit: 2), runner: runner, batch_sleeper: sleeper)

      expect_raises(Meridian::Deploy::DeployFailed, /status 500/) do
        orchestrator.deploy
      end

      sleeps.should be_empty
    end

    it "rejects a boot limit smaller than one" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(content: multi_host_config(boot_limit: 0), runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /boot.limit must be at least 1/) do
        orchestrator.deploy
      end
    end

    it "rejects a negative boot wait" do
      runner = FakeSSHRunner.new
      orchestrator = build_orchestrator(content: multi_host_config(boot_wait: -1), runner: runner)

      expect_raises(Meridian::Deploy::DeployFailed, /boot.wait must be non-negative/) do
        orchestrator.deploy
      end
    end
  end
end
