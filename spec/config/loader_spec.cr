require "../spec_helper"

describe "Meridian::Config::Loader" do
  describe ".parse" do
    it "parses config content without reading from disk" do
      config = Meridian::Config::Loader.parse(MINIMAL_CONFIG)

      config.service.should eq("myapp")
      config.image.should eq("registry.example.com/myorg/myapp")
    end

    it "raises a validation error when build config is present" do
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

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.parse(yaml)
      end

      message = ex.message || raise "Expected validation error message"
      message.should contain("build")
      message.should contain("not yet supported")
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

    it "parses a per-role image override" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
          workers:
            hosts:
              - 192.168.1.12
            image: ghcr.io/myorg/myapp-worker:latest
      YAML

      config = Meridian::Config::Loader.load(write_config(yaml))
      config.servers["workers"].image.should eq("ghcr.io/myorg/myapp-worker:latest")
    end

    it "leaves server image nil when no per-role image is set" do
      config = Meridian::Config::Loader.load(write_config(FULL_CONFIG))
      config.servers["workers"].image.should be_nil
    end

    it "raises a validation error for unknown keys on a server role" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            unknown_key: bad
      YAML

      expect_raises(Meridian::Config::ValidationError, /unknown_key/) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
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

    it "parses stream transfer mode without requiring a registry block" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        transfer:
          mode: stream
      YAML

      config = Meridian::Config::Loader.load(write_config(yaml))
      config.transfer.try(&.mode).should eq(Meridian::Config::TransferMode::Stream)
      config.registry.should be_nil
    end

    it "raises a validation error when replicas is configured" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            replicas: 2
      YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end

      message = ex.message || raise "Expected validation error message"
      message.should contain("replicas")
    end

    it "raises a validation error when response_buffer is configured" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            proxy:
              response_buffer: 1024
      YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end

      message = ex.message || raise "Expected validation error message"
      message.should contain("response_buffer")
    end

    it "raises a validation error for unknown config keys" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
            typo: true
      YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end

      message = ex.message || raise "Expected validation error message"
      message.should contain("typo")
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

    it "raises a descriptive error when transfer.mode is missing" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        transfer: {}
      YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
      message = ex.message || raise "Expected validation error message"
      message.should contain("transfer.mode")
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

    it "parses a files block with source, destination, template, and roles" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        files:
          - source: config/Caddyfile.ecr
            destination: /home/deploy/Caddyfile
            template: true
            roles:
              - web
      YAML

      config = Meridian::Config::Loader.load(write_config(yaml))

      config.files.size.should eq(1)
      config.files[0].source.should eq("config/Caddyfile.ecr")
      config.files[0].destination.should eq("/home/deploy/Caddyfile")
      config.files[0].template?.should be_true
      config.files[0].roles.should eq(["web"])
    end

    it "defaults template to false and roles to nil when omitted" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        files:
          - source: config/nginx.conf
            destination: /home/deploy/nginx.conf
      YAML

      config = Meridian::Config::Loader.load(write_config(yaml))

      config.files[0].template?.should be_false
      config.files[0].roles.should be_nil
    end

    it "defaults files to an empty array when not present" do
      config = Meridian::Config::Loader.load(write_config(MINIMAL_CONFIG))

      config.files.should be_empty
    end

    it "raises a validation error for an unknown key in a files entry" do
      yaml = <<-YAML
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        files:
          - source: config/Caddyfile
            destination: /home/deploy/Caddyfile
            unknown_key: oops
      YAML

      ex = expect_raises(Meridian::Config::ValidationError) do
        Meridian::Config::Loader.load(write_config(yaml))
      end
      message = ex.message || raise "Expected validation error message"
      message.should contain("files[0].unknown_key")
    end
  end
end
