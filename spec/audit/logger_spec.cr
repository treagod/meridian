require "../spec_helper"

private def build_audit_logger(runner : FakeSSHRunner)
  config = load_config(MINIMAL_CONFIG)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Audit::Logger.new(
    config,
    executor,
    -> { Time.utc(2026, 5, 21, 10, 0, 0) },
    -> { "tester@spec" }
  )
end

describe "Meridian::Audit::Logger" do
  describe "#record" do
    it "appends a line-oriented entry to the host audit log" do
      runner = FakeSSHRunner.new
      logger = build_audit_logger(runner)

      logger.record("192.168.1.10", "deploy", "role=web")

      invocation = runner.invocations.last
      invocation.host.should eq("192.168.1.10")
      invocation.remote_command.should eq(
        "sh -c 'mkdir -p .local/state/meridian/services/myapp && " \
        "cat >> .local/state/meridian/services/myapp/audit.log'"
      )
      invocation.input.should eq(
        "2026-05-21T10:00:00Z | tester@spec | deploy | role=web\n"
      )
    end

    it "never raises when the audit write fails" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(exit_code: 1, stdout: "", stderr: "disk full\n")
      logger = build_audit_logger(runner)

      logger.record("192.168.1.10", "deploy", "role=web")
    end
  end

  describe "#recent" do
    it "tails and parses recent audit entries" do
      runner = FakeSSHRunner.new
      runner.next_result = Meridian::SSH::Result.new(
        exit_code: 0,
        stdout: "2026-05-21T09:00:00Z | ops | lock | acquired\n" \
                "2026-05-21T09:05:00Z | ops | deploy | role=web\n",
        stderr: ""
      )
      logger = build_audit_logger(runner)

      entries = logger.recent("192.168.1.10", 20)

      entries.map(&.action).should eq(["lock", "deploy"])
      runner.invocations.last.remote_command.should eq(
        "sh -c 'tail -n 20 .local/state/meridian/services/myapp/audit.log 2>/dev/null || true'"
      )
    end
  end
end
