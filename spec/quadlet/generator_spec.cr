require "../spec_helper"

def build_quadlet_generator(content : String = FULL_CONFIG)
  Meridian::Quadlet::Generator.new(load_config(content))
end

describe "Meridian::Quadlet::Generator" do
  describe "#container_file" do
    it "includes the [Container] section header" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("[Container]")
    end

    it "sets the image to the configured image value" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Image=registry.example.com/myorg/myapp")
    end

    it "sets the container name to include the service and colour" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("ContainerName=myapp-green")
    end

    it "sets the container name to blue when colour is blue" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Blue)

      output.should contain("ContainerName=myapp-blue")
    end

    it "includes clear environment variables" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Environment=RAILS_ENV=production")
      output.should contain("Environment=DATABASE_HOST=db.internal")
    end

    it "includes the [Service] restart policy" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("[Service]")
      output.should contain("Restart=always")
    end

    it "includes the [Install] section" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("[Install]")
      output.should contain("WantedBy=multi-user.target")
    end

    it "includes the network reference" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Network=myapp.network")
    end

    it "overrides CMD when a custom cmd is configured" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["workers"], Meridian::Quadlet::Color::Green)

      output.should contain("Exec=bin/sidekiq")
    end
  end

  describe "#network_file" do
    it "includes the [Network] section header" do
      output = build_quadlet_generator.network_file

      output.should contain("[Network]")
    end

    it "names the network after the service" do
      output = build_quadlet_generator.network_file

      output.should contain("NetworkName=myapp")
    end
  end

  describe "#proxy_container_file" do
    it "uses the configured proxy image" do
      output = build_quadlet_generator.proxy_container_file

      output.should contain("Image=ghcr.io/basecamp/kamal-proxy:latest")
    end

    it "falls back to the pinned default proxy image when none is configured" do
      config = load_config(<<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        proxy:
          http_port: 80
          https_port: 443
      YAML
      output = Meridian::Quadlet::Generator.new(config).proxy_container_file

      output.should contain("Image=basecamp/kamal-proxy:v0.9.2")
    end

    it "publishes port 80" do
      output = build_quadlet_generator.proxy_container_file

      output.should contain("PublishPort=80:80")
    end

    it "publishes port 443" do
      output = build_quadlet_generator.proxy_container_file

      output.should contain("PublishPort=443:443")
    end

    it "names the container kamal-proxy" do
      output = build_quadlet_generator.proxy_container_file

      output.should contain("ContainerName=kamal-proxy")
    end
  end

  describe "#write_to_directory" do
    it "creates a .container file in the output directory" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "myapp-green.container")).should be_true
      end
    end

    it "creates a .network file in the output directory" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "myapp.network")).should be_true
      end
    end

    it "creates a proxy .container file in the output directory" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "kamal-proxy.container")).should be_true
      end
    end

    it "does not create files for the inactive colour" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "myapp-blue.container")).should be_false
      end
    end
  end
end
