require "../spec_helper"

describe "Meridian::Commands::Accessory" do
  describe "#start" do
    pending "uploads a Quadlet file for the accessory to its designated host"
    pending "targets the host defined in the accessory configuration"
    pending "runs daemon-reload before starting the accessory"
    pending "publishes the configured port"
    pending "mounts the configured volume"
    pending "raises UnknownAccessory when the named accessory does not exist in the config"
  end

  describe "#stop" do
    pending "stops the accessory systemd service"
    pending "does not affect any web or worker services"
  end

  describe "#logs" do
    pending "runs journalctl for the accessory service"
  end
end
