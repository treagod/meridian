require "../spec_helper"

record HealthRequest, request_target : String, timeout : Time::Span

class FakeHealthTransport < Meridian::Health::Transport
  getter requests = [] of HealthRequest

  def initialize(@outcomes : Array(Int32 | IO::Error))
  end

  def get(uri : URI, timeout : Time::Span) : HTTP::Client::Response
    @requests << HealthRequest.new(request_target: uri.request_target, timeout: timeout)
    outcome = @outcomes.shift? || 200

    case outcome
    in Int32
      HTTP::Client::Response.new(outcome)
    in IO::Error
      raise outcome
    end
  end
end

def noop_sleep : Proc(Time::Span, Nil)
  ->(_duration : Time::Span) { nil }
end

describe "Meridian::Health::Checker" do
  describe "#poll" do
    it "returns true when the endpoint responds with HTTP 200" do
      transport = FakeHealthTransport.new([200] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      result = checker.poll(
        "http://example.test/health",
        interval: 1.millisecond,
        timeout: 50.milliseconds,
        retries: 2
      )

      result.should be_true
    end

    it "does not sleep after a successful check" do
      transport = FakeHealthTransport.new([200] of Int32 | IO::Error)
      sleeps = [] of Time::Span
      sleeper = ->(duration : Time::Span) { sleeps << duration }
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: sleeper)

      result = checker.poll(
        "http://example.test/health",
        interval: 1.millisecond,
        timeout: 50.milliseconds,
        retries: 3
      )

      result.should be_true
      sleeps.should be_empty
    end

    it "raises CheckFailed after exhausting retries when the server returns 500" do
      transport = FakeHealthTransport.new([500, 500, 500] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      expect_raises(Meridian::Health::CheckFailed, /status 500/) do
        checker.poll(
          "http://example.test/health",
          interval: 1.millisecond,
          timeout: 50.milliseconds,
          retries: 3
        )
      end
    end

    it "raises CheckFailed when no server is listening" do
      transport = FakeHealthTransport.new([
        IO::Error.new("Connection refused"),
        IO::Error.new("Connection refused"),
      ] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      expect_raises(Meridian::Health::CheckFailed) do
        checker.poll(
          "http://example.test/health",
          interval: 1.millisecond,
          timeout: 50.milliseconds,
          retries: 2
        )
      end
    end

    it "retries the configured number of times before failing" do
      transport = FakeHealthTransport.new([500, 500, 500, 500] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      expect_raises(Meridian::Health::CheckFailed) do
        checker.poll(
          "http://example.test/health",
          interval: 1.millisecond,
          timeout: 50.milliseconds,
          retries: 4
        )
      end

      transport.requests.size.should eq(4)
    end

    it "succeeds on a later retry if the server becomes healthy" do
      transport = FakeHealthTransport.new([500, 500, 200] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      result = checker.poll(
        "http://example.test/health",
        interval: 1.millisecond,
        timeout: 50.milliseconds,
        retries: 3
      )

      result.should be_true
      transport.requests.size.should eq(3)
    end

    it "uses the configured URL path" do
      transport = FakeHealthTransport.new([200] of Int32 | IO::Error)
      checker = Meridian::Health::Checker.new(output: IO::Memory.new, transport: transport, sleeper: noop_sleep)

      result = checker.poll(
        "http://example.test/ready?full=1",
        interval: 1.millisecond,
        timeout: 50.milliseconds,
        retries: 2
      )

      result.should be_true
      transport.requests.last.request_target.should eq("/ready?full=1")
    end

    it "prefixes log lines when a label is provided" do
      transport = FakeHealthTransport.new([200] of Int32 | IO::Error)
      output = IO::Memory.new
      checker = Meridian::Health::Checker.new(output: output, transport: transport, sleeper: noop_sleep, label: "web-1")

      checker.poll(
        "http://example.test/health",
        interval: 1.millisecond,
        timeout: 50.milliseconds,
        retries: 2
      )

      output.to_s.should contain("[web-1] Health check attempt 1/2: http://example.test/health")
      output.to_s.should contain("[web-1] Health check passed: http://example.test/health")
    end
  end
end
