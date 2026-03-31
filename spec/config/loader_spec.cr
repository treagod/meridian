require "../spec_helper"

describe "Meridian::Config::Loader" do
  describe ".parse" do
    it "parses config content without reading from disk" do
      config = Meridian::Config::Loader.parse(MINIMAL_CONFIG)

      config.service.should eq("myapp")
      config.image.should eq("registry.example.com/myorg/myapp")
    end

    it "parses the build block when present" do
      yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp

          build:
            dockerfile: Dockerfile.prod
            context: .
            args:
              RAILS_ENV: production
            platform: linux/amd64
            builder: remote-builder

          servers:
            web:
              hosts:
                - 192.168.1.10
        YAML

      config = Meridian::Config::Loader.parse(yaml)
      build = config.build || raise "Expected build config"

      build.dockerfile.should eq("Dockerfile.prod")
      build.context.should eq(".")
      build.args["RAILS_ENV"].should eq("production")
      build.platform.should eq("linux/amd64")
      build.builder.should eq("remote-builder")
    end
  end

  describe ".load" do
    it "parses the service name" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.service.should eq("myapp")
    end

    it "parses the image name" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.image.should eq("registry.example.com/myorg/myapp")
    end

    it "parses web server hosts" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.servers["web"].hosts.should eq(["192.168.1.10", "192.168.1.11"])
    end

    it "parses the workers role hosts" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.servers["workers"].hosts.should eq(["192.168.1.12"])
    end

    it "parses a custom CMD for the workers role" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.servers["workers"].cmd.should eq("bin/sidekiq")
    end

    it "parses the proxy image" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      proxy = config.proxy || raise "Expected proxy config"
      proxy.image.should eq("ghcr.io/basecamp/kamal-proxy:latest")
    end

    it "parses the proxy host" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      server_proxy = config.servers["web"].proxy || raise "Expected web proxy config"
      server_proxy.host.should eq("myapp.example.com")
    end

    it "parses the registry server" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      registry = config.registry || raise "Expected registry config"
      registry.server.should eq("registry.example.com")
    end

    it "parses clear environment variables" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      env = config.env || raise "Expected environment config"
      env.clear["RAILS_ENV"].should eq("production")
    end

    it "parses secret environment variable names" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      env = config.env || raise "Expected environment config"
      env.secret.should contain("SECRET_KEY_BASE")
    end

    it "applies the default SSH user of 'deploy'" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.ssh.user.should eq("deploy")
    end

    it "applies the default SSH port of 22" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.ssh.port.should eq(22)
    end

    it "applies the default boot limit of 1" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.boot.limit.should eq(1)
    end

    it "applies the default healthcheck path of /health" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      server_proxy = config.servers["web"].proxy || raise "Expected web proxy config"
      server_proxy.healthcheck.path.should eq("/health")
    end

    it "parses the accessory image" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      accessories = config.accessories || raise "Expected accessories config"
      accessories["db"].image.should eq("docker.io/library/postgres:16")
    end

    it "parses the accessory host" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      accessories = config.accessories || raise "Expected accessories config"
      accessories["db"].host.should eq("192.168.1.20")
    end

    it "raises a descriptive error when the service key is missing" do
      yaml = <<-YAML
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
        YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
      message = ex.message || raise "Expected validation error message"
      message.should contain("service")
    end

    it "raises a descriptive error when the image key is missing" do
      yaml = <<-YAML
          service: myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
        YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
      message = ex.message || raise "Expected validation error message"
      message.should contain("image")
    end

    it "raises a descriptive error when no servers are defined" do
      yaml = <<-YAML
          service: myapp
          image: registry.example.com/myorg/myapp

          proxy:
            image: ghcr.io/basecamp/kamal-proxy:latest
        YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
      message = ex.message || raise "Expected validation error message"
      message.should contain("servers")
    end

    it "raises an error when the config file does not exist" do
      expect_raises(File::NotFoundError) do
        Meridian::Config::Loader.load("/nonexistent/path/deploy.yml")
      end
    end

    it "raises an error when the YAML is malformed" do
      expect_raises(YAML::ParseException) do
        Meridian::Config::Loader.load(write_config("service: [unclosed"))
      end
    end
  end
end
