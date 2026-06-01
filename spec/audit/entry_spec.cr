require "../spec_helper"

describe "Meridian::Audit::Entry" do
  it "renders a line-oriented entry" do
    entry = Meridian::Audit::Entry.new(
      timestamp: "2026-05-21T10:00:00Z",
      actor: "ops@ci",
      action: "deploy",
      detail: "role=web image=registry.example.com/myorg/myapp"
    )

    entry.to_line.should eq(
      "2026-05-21T10:00:00Z | ops@ci | deploy | role=web image=registry.example.com/myorg/myapp"
    )
  end

  it "collapses whitespace so each entry stays on one line" do
    entry = Meridian::Audit::Entry.new(
      timestamp: "2026-05-21T10:00:00Z",
      actor: "ops",
      action: "deploy",
      detail: "first\nsecond"
    )

    entry.to_line.lines.size.should eq(1)
    entry.to_line.should end_with("first second")
  end

  it "parses a rendered entry back" do
    parsed = Meridian::Audit::Entry.parse(
      "2026-05-21T10:00:00Z | ops@ci | rollback | to green"
    )

    parsed = value!(parsed)
    parsed.timestamp.should eq("2026-05-21T10:00:00Z")
    parsed.actor.should eq("ops@ci")
    parsed.action.should eq("rollback")
    parsed.detail.should eq("to green")
  end

  it "returns nil for malformed lines" do
    Meridian::Audit::Entry.parse("not an audit line").should be_nil
    Meridian::Audit::Entry.parse("").should be_nil
  end
end
