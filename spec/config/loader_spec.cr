require "../spec_helper"

describe "Meridian::Config::Loader" do
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
      config.proxy.not_nil!.image.should eq("ghcr.io/basecamp/kamal-proxy:latest")
    end

    it "parses the proxy host" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.servers["web"].proxy.not_nil!.host.should eq("myapp.example.com")
    end

    it "parses the registry server" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))
      config.registry.not_nil!.server.should eq("registry.example.com")
    end

    it "parses clear environment variables" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.env.not_nil!.clear["RAILS_ENV"].should eq("production")
    end

    it "parses secret environment variable names" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.env.not_nil!.secret.should contain("SECRET_KEY_BASE")
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
      config.servers["web"].proxy.not_nil!.healthcheck.path.should eq("/health")
    end

    it "parses the accessory image" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.accessories.not_nil!["db"].image.should eq("docker.io/library/postgres:16")
    end

    it "parses the accessory host" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.accessories.not_nil!["db"].host.should eq("192.168.1.20")
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
      ex.message.not_nil!.should contain("service")
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
      ex.message.not_nil!.should contain("image")
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
      ex.message.not_nil!.should contain("servers")
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
