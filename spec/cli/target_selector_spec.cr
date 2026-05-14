require "../spec_helper"

private SELECTOR_CONFIG = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
          - 192.168.1.11
        proxy:
          host: myapp.example.com
          ssl: true
          healthcheck:
            path: /health
            interval: 2
            timeout: 5
            retries: 10
      workers:
        hosts:
          - 192.168.1.12
          - 192.168.1.13
        cmd: bin/sidekiq

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest
  YAML

private SHARED_HOST_CONFIG = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
        proxy:
          host: myapp.example.com
          ssl: true
          healthcheck:
            path: /health
            interval: 2
            timeout: 5
            retries: 10
      workers:
        hosts:
          - 192.168.1.10
          - 192.168.1.20

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest
  YAML

private NO_WEB_CONFIG = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      workers:
        hosts:
          - 192.168.1.12
  YAML

describe Meridian::CLI::TargetSelector do
  describe "#resolve" do
    it "returns all role/host pairs when empty" do
      config = load_config(SELECTOR_CONFIG)
      selector = Meridian::CLI::TargetSelector.new

      targets = selector.resolve(config)

      targets.map { |target| {target.role, target.host} }.should eq([
        {"web", "192.168.1.10"},
        {"web", "192.168.1.11"},
        {"workers", "192.168.1.12"},
        {"workers", "192.168.1.13"},
      ])
    end

    it "filters to a single role" do
      selector = Meridian::CLI::TargetSelector.new
      selector.role = "workers"

      targets = selector.resolve(load_config(SELECTOR_CONFIG))

      targets.map(&.host).should eq(["192.168.1.12", "192.168.1.13"])
      targets.all? { |target| target.role == "workers" }.should be_true
    end

    it "filters to a single host" do
      selector = Meridian::CLI::TargetSelector.new
      selector.host = "192.168.1.11"

      targets = selector.resolve(load_config(SELECTOR_CONFIG))

      targets.size.should eq(1)
      targets.first.role.should eq("web")
      targets.first.host.should eq("192.168.1.11")
    end

    it "returns one entry per role when a host is shared across roles" do
      selector = Meridian::CLI::TargetSelector.new
      selector.host = "192.168.1.10"

      targets = selector.resolve(load_config(SHARED_HOST_CONFIG))

      targets.map(&.role).should eq(["web", "workers"])
    end

    it "filters to a specific role + host pair" do
      selector = Meridian::CLI::TargetSelector.new
      selector.role = "web"
      selector.host = "192.168.1.10"

      targets = selector.resolve(load_config(SELECTOR_CONFIG))

      targets.should eq([Meridian::CLI::TargetSelector::Target.new(role: "web", host: "192.168.1.10")])
    end

    it "returns the first web host when --primary is set" do
      selector = Meridian::CLI::TargetSelector.new
      selector.primary = true

      targets = selector.resolve(load_config(SELECTOR_CONFIG))

      targets.should eq([Meridian::CLI::TargetSelector::Target.new(role: "web", host: "192.168.1.10")])
    end

    it "raises for an unknown role and lists valid roles" do
      selector = Meridian::CLI::TargetSelector.new
      selector.role = "nope"

      expect_raises(ArgumentError, /Unknown role: nope\. Valid roles: web, workers/) do
        selector.resolve(load_config(SELECTOR_CONFIG))
      end
    end

    it "raises for an unknown host and lists valid hosts" do
      selector = Meridian::CLI::TargetSelector.new
      selector.host = "10.0.0.1"

      expect_raises(ArgumentError, /Unknown host: 10\.0\.0\.1\. Valid hosts: 192\.168\.1\.10, 192\.168\.1\.11, 192\.168\.1\.12, 192\.168\.1\.13/) do
        selector.resolve(load_config(SELECTOR_CONFIG))
      end
    end

    it "raises when host is not in the explicit role" do
      selector = Meridian::CLI::TargetSelector.new
      selector.role = "workers"
      selector.host = "192.168.1.10"

      expect_raises(ArgumentError, /Host 192\.168\.1\.10 is not configured for role: workers/) do
        selector.resolve(load_config(SELECTOR_CONFIG))
      end
    end

    it "raises when --primary is combined with --role" do
      selector = Meridian::CLI::TargetSelector.new
      selector.primary = true
      selector.role = "workers"

      expect_raises(ArgumentError, /--primary cannot be combined with --role/) do
        selector.resolve(load_config(SELECTOR_CONFIG))
      end
    end

    it "raises when --primary is combined with --host" do
      selector = Meridian::CLI::TargetSelector.new
      selector.primary = true
      selector.host = "192.168.1.10"

      expect_raises(ArgumentError, /--primary cannot be combined with --host/) do
        selector.resolve(load_config(SELECTOR_CONFIG))
      end
    end

    it "raises when --primary is used without a web role" do
      selector = Meridian::CLI::TargetSelector.new
      selector.primary = true

      expect_raises(ArgumentError, /--primary requires a 'web' role/) do
        selector.resolve(load_config(NO_WEB_CONFIG))
      end
    end
  end

  describe "#register" do
    it "wires --role/--host/--primary into an OptionParser" do
      selector = Meridian::CLI::TargetSelector.new
      parser = OptionParser.new
      selector.register(parser)

      parser.parse(["--role", "workers", "--host", "192.168.1.13", "--primary"])

      selector.role.should eq("workers")
      selector.host.should eq("192.168.1.13")
      selector.primary?.should be_true
    end

    it "can opt out of individual flags" do
      selector = Meridian::CLI::TargetSelector.new
      parser = OptionParser.new
      selector.register(parser, primary: false, role: false)

      parser.parse(["--host", "h"])
      selector.host.should eq("h")
      selector.role.should be_nil
      selector.primary?.should be_false
    end
  end
end
