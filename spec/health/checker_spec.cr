require "../spec_helper"

describe "Meridian::Health::Checker" do
  describe "#poll" do
    pending "returns true when the endpoint responds with HTTP 200"
    pending "raises HealthCheckFailed after exhausting retries when the server returns 500"
    pending "raises HealthCheckFailed when no server is listening"
    pending "retries the configured number of times before failing"
    pending "succeeds on a later retry if the server becomes healthy"
    pending "uses the configured URL path"
  end
end
