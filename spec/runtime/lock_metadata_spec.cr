require "../spec_helper"

describe "Meridian::Runtime::LockMetadata" do
  it "describes the holder, time, and message" do
    metadata = Meridian::Runtime::LockMetadata.new(
      actor: "ops@ci",
      acquired_at: "2026-05-21T10:00:00Z",
      message: "scheduled maintenance"
    )

    metadata.describe.should eq("held by ops@ci since 2026-05-21T10:00:00Z: scheduled maintenance")
  end

  it "omits the message segment when no message is recorded" do
    metadata = Meridian::Runtime::LockMetadata.new(
      actor: "ops@ci",
      acquired_at: "2026-05-21T10:00:00Z"
    )

    metadata.describe.should eq("held by ops@ci since 2026-05-21T10:00:00Z")
  end

  it "round-trips through JSON" do
    metadata = Meridian::Runtime::LockMetadata.new(
      actor: "ops@ci",
      acquired_at: "2026-05-21T10:00:00Z",
      message: "deploy"
    )

    restored = Meridian::Runtime::LockMetadata.from_json(metadata.to_json)
    restored.actor.should eq("ops@ci")
    restored.acquired_at.should eq("2026-05-21T10:00:00Z")
    restored.message.should eq("deploy")
  end
end
