require "../spec_helper"

describe "Meridian::Runtime::ReleaseState" do
  describe ".promote" do
    it "stores the new release as current with no previous when no prior state exists" do
      record = Meridian::Runtime::ReleaseRecord.new(
        service: "myapp", role: "web", host: "h",
        color: "blue", image: "img", release_id: "r1", deployed_at: "t1"
      )

      state = Meridian::Runtime::ReleaseState.promote(nil, record)

      state.current.release_id.should eq("r1")
      state.previous.should be_nil
      state.schema_version.should eq(1)
    end

    it "demotes the prior current to previous" do
      first = Meridian::Runtime::ReleaseRecord.new(
        service: "myapp", role: "web", host: "h",
        color: "blue", image: "img", release_id: "r1", deployed_at: "t1"
      )
      second = Meridian::Runtime::ReleaseRecord.new(
        service: "myapp", role: "web", host: "h",
        color: "green", image: "img", release_id: "r2", deployed_at: "t2"
      )

      first_state = Meridian::Runtime::ReleaseState.promote(nil, first)
      second_state = Meridian::Runtime::ReleaseState.promote(first_state, second)

      second_state.current.release_id.should eq("r2")
      value!(second_state.previous).release_id.should eq("r1")
    end

    it "drops the older previous when a third release lands" do
      r1 = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "blue", image: "i", release_id: "r1", deployed_at: "t")
      r2 = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "green", image: "i", release_id: "r2", deployed_at: "t")
      r3 = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "blue", image: "i", release_id: "r3", deployed_at: "t")

      state = Meridian::Runtime::ReleaseState.promote(nil, r1)
      state = Meridian::Runtime::ReleaseState.promote(state, r2)
      state = Meridian::Runtime::ReleaseState.promote(state, r3)

      state.current.release_id.should eq("r3")
      value!(state.previous).release_id.should eq("r2")
    end
  end

  describe "#swap" do
    it "exchanges current and previous" do
      a = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "blue", image: "i", release_id: "a", deployed_at: "t")
      b = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "green", image: "i", release_id: "b", deployed_at: "t")
      state = Meridian::Runtime::ReleaseState.new(current: a, previous: b)

      swapped = state.swap

      swapped.current.release_id.should eq("b")
      value!(swapped.previous).release_id.should eq("a")
    end

    it "raises when there is no previous release" do
      a = Meridian::Runtime::ReleaseRecord.new(service: "s", role: "web", host: "h", color: "blue", image: "i", release_id: "a", deployed_at: "t")
      state = Meridian::Runtime::ReleaseState.new(current: a)

      expect_raises(ArgumentError, /Cannot swap/) do
        state.swap
      end
    end
  end

  describe "JSON round-trip" do
    it "preserves all release record fields" do
      record = Meridian::Runtime::ReleaseRecord.new(
        service: "myapp", role: "web", host: "192.168.1.10",
        color: "green", image: "registry.example.com/myorg/myapp",
        release_id: "20260519T120000Z", deployed_at: "2026-05-19T12:00:00Z"
      )
      state = Meridian::Runtime::ReleaseState.new(current: record)

      decoded = Meridian::Runtime::ReleaseState.from_json(state.to_json)

      decoded.current.service.should eq("myapp")
      decoded.current.role.should eq("web")
      decoded.current.host.should eq("192.168.1.10")
      decoded.current.color.should eq("green")
      decoded.current.image.should eq("registry.example.com/myorg/myapp")
      decoded.current.release_id.should eq("20260519T120000Z")
      decoded.current.deployed_at.should eq("2026-05-19T12:00:00Z")
      decoded.previous.should be_nil
    end
  end
end
