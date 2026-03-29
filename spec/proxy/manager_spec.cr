require "../spec_helper"

describe "Meridian::Proxy::Manager" do
  describe "#setup" do
    pending "uploads a kamal-proxy Quadlet file to each web host"
    pending "runs daemon-reload on each web host after uploading"
    pending "starts kamal-proxy via systemctl on each web host"
    pending "does not touch worker hosts during proxy setup"
  end

  describe "#remove" do
    pending "stops kamal-proxy on each web host"
    pending "removes the kamal-proxy Quadlet file from each web host"
  end
end
