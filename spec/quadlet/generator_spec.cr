require "../spec_helper"

describe "Meridian::Quadlet::Generator" do
  describe "#container_file" do
    pending "includes the [Container] section header"
    pending "sets the image to the configured image value"
    pending "sets the container name to include the service and colour"
    pending "sets the container name to blue when colour is blue"
    pending "includes clear environment variables"
    pending "includes the [Service] restart policy"
    pending "includes the [Install] section"
    pending "includes the network reference"
    pending "overrides CMD when a custom cmd is configured"
  end

  describe "#network_file" do
    pending "includes the [Network] section header"
    pending "names the network after the service"
  end

  describe "#proxy_container_file" do
    pending "uses the configured proxy image"
    pending "publishes port 80"
    pending "publishes port 443"
    pending "names the container kamal-proxy"
  end

  describe "#write_to_directory" do
    pending "creates a .container file in the output directory"
    pending "creates a .network file in the output directory"
    pending "creates a proxy .container file in the output directory"
    pending "does not create files for the inactive colour"
  end
end
