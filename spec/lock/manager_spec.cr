require "../spec_helper"

private LOCK_DIRECTORY = ".local/state/meridian/services/myapp/lock"
private LOCK_METADATA  = ".local/state/meridian/services/myapp/lock/meta.json"

private def ssh_fail(exit_code : Int32 = 1, stdout : String = "", stderr : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr)
end

private def build_lock_manager(
  runner : FakeSSHRunner,
  output : IO = IO::Memory.new,
  audit : FakeAuditLogger? = nil,
)
  config = load_config(MINIMAL_CONFIG)
  executor = Meridian::SSH::Executor.new(runner: runner)
  Meridian::Lock::Manager.new(
    config,
    executor,
    output,
    -> { Time.utc(2026, 5, 21, 10, 0, 0) },
    -> { "tester@spec" },
    audit_logger: audit || FakeAuditLogger.new(config)
  )
end

private def held_metadata_json : String
  Meridian::Runtime::LockMetadata.new(
    actor: "ops@ci",
    acquired_at: "2026-05-20T09:00:00Z",
    message: "maintenance"
  ).to_json
end

describe "Meridian::Lock::Manager" do
  describe "#acquire" do
    it "claims the lock atomically with a plain mkdir of the lock directory" do
      runner = FakeSSHRunner.new
      manager = build_lock_manager(runner)

      manager.acquire

      remote_commands_for(runner).should contain("mkdir #{LOCK_DIRECTORY}")
    end

    it "uploads lock metadata describing who/when/message" do
      runner = FakeSSHRunner.new
      manager = build_lock_manager(runner)

      manager.acquire("scheduled maintenance")

      upload = runner.invocations.find(&.remote_command.==("cat > #{LOCK_METADATA}")) ||
               raise "Expected lock metadata upload"
      metadata = Meridian::Runtime::LockMetadata.from_json(upload.input.not_nil!)
      metadata.actor.should eq("tester@spec")
      metadata.acquired_at.should eq("2026-05-21T10:00:00Z")
      metadata.message.should eq("scheduled maintenance")
    end

    it "records an audit entry on the lock host" do
      runner = FakeSSHRunner.new
      audit = FakeAuditLogger.new(load_config(MINIMAL_CONFIG))
      manager = build_lock_manager(runner, audit: audit)

      manager.acquire("deploy")

      entry = audit.recorded.find(&.action.== "lock") || raise "Expected lock audit entry"
      entry.host.should eq("192.168.1.10")
      entry.detail.should eq("acquired: deploy")
    end

    it "raises LockHeld with the existing holder when the lock already exists" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        ssh_ok,                           # mkdir -p service directory
        ssh_fail(1, "", "File exists\n"), # mkdir lock directory
        ssh_ok,                           # test -d lock directory
        ssh_ok(held_metadata_json)        # cat lock metadata
      )
      manager = build_lock_manager(runner)

      expect_raises(Meridian::Lock::LockHeld, /held by ops@ci since 2026-05-20T09:00:00Z: maintenance/) do
        manager.acquire
      end
    end

    it "raises LockError when mkdir fails for a reason other than contention" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(
        ssh_ok,                                 # mkdir -p service directory
        ssh_fail(1, "", "Permission denied\n"), # mkdir lock directory
        ssh_fail(1, "", "")                     # test -d lock directory
      )
      manager = build_lock_manager(runner)

      expect_raises(Meridian::Lock::LockError, /Failed to acquire deploy lock/) do
        manager.acquire
      end
    end
  end

  describe "#status" do
    it "reports the holder when a lock is held" do
      runner = FakeSSHRunner.new
      runner.enqueue_results(ssh_ok, ssh_ok(held_metadata_json))
      manager = build_lock_manager(runner)

      status = manager.status

      status.held.should be_true
      status.host.should eq("192.168.1.10")
      status.metadata.not_nil!.actor.should eq("ops@ci")
    end

    it "reports no lock when the lock directory is absent" do
      runner = FakeSSHRunner.new
      runner.next_result = ssh_fail(1, "", "")
      manager = build_lock_manager(runner)

      manager.status.held.should be_false
    end
  end

  describe "#release" do
    it "removes the lock directory and announces what it released" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      runner.enqueue_results(ssh_ok, ssh_ok(held_metadata_json), ssh_ok)
      manager = build_lock_manager(runner, output: output)

      manager.release

      remote_commands_for(runner).should contain("rm -rf #{LOCK_DIRECTORY}")
      output.to_s.should contain("Releasing deploy lock on 192.168.1.10")
      output.to_s.should contain("held by ops@ci")
    end

    it "reports when no lock is held instead of failing silently" do
      runner = FakeSSHRunner.new
      output = IO::Memory.new
      runner.next_result = ssh_fail(1, "", "")
      manager = build_lock_manager(runner, output: output)

      manager.release.should be_nil
      output.to_s.should contain("No deploy lock held on 192.168.1.10")
    end
  end
end
