require "../spec_helper"

def build_quadlet_generator(content : String = FULL_CONFIG)
  Meridian::Quadlet::Generator.new(load_config(content))
end

def accessory_generator_config : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10

    accessories:
      db:
        image: docker.io/library/postgres:16
        host: 192.168.1.20
        port: "5432:5432"
        volumes:
          - pgdata:/var/lib/postgresql/data
        env:
          clear:
            POSTGRES_DB: meridian
        cmd: postgres -c shared_buffers=256MB
  YAML
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
      output.should contain("WantedBy=default.target")
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

    it "emits Secret= directives for each env.secret name injected as env vars" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Secret=SECRET_KEY_BASE,type=env,target=SECRET_KEY_BASE")
      output.should contain("Secret=DATABASE_URL,type=env,target=DATABASE_URL")
    end

    it "includes a [Unit] section with a description" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("[Unit]")
      output.should contain("Description=myapp (green)")
    end

    it "emits Volume= lines when volumes are configured" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          volumes:
            - /data/uploads:/app/uploads
            - logs:/var/log/app
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Volume=/data/uploads:/app/uploads")
      output.should contain("Volume=logs:/var/log/app")
    end

    it "emits PublishPort= lines when ports are configured" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          ports:
            - "8080:8080"
            - "9090:9090"
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("PublishPort=8080:8080")
      output.should contain("PublishPort=9090:9090")
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

  describe "#accessory_container_file" do
    it "names the accessory container after the accessory key" do
      config = load_config(FULL_CONFIG)
      accessory = config.accessories.not_nil!["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("ContainerName=db")
      output.should contain("Image=docker.io/library/postgres:16")
    end

    it "publishes the configured port and mounts volumes" do
      config = load_config(FULL_CONFIG)
      accessory = config.accessories.not_nil!["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("PublishPort=5432:5432")
      output.should contain("Volume=pgdata:/var/lib/postgresql/data")
    end

    it "includes clear environment variables and command overrides" do
      config = load_config(accessory_generator_config)
      accessory = config.accessories.not_nil!["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("Environment=POSTGRES_DB=meridian")
      output.should contain("Exec=postgres -c shared_buffers=256MB")
    end

    it "emits Secret= directives for each accessory env.secret name injected as env vars" do
      config = load_config(FULL_CONFIG)
      accessory = config.accessories.not_nil!["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("Secret=POSTGRES_PASSWORD,type=env,target=POSTGRES_PASSWORD")
    end

    it "includes a [Unit] section with a description" do
      config = load_config(FULL_CONFIG)
      accessory = config.accessories.not_nil!["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("[Unit]")
      output.should contain("Description=db")
    end

    it "emits Network= when network is configured" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.20
              network: myapp.network
        YAML
      accessory = config.accessories.not_nil!["cache"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("cache", accessory)

      output.should contain("Network=myapp.network")
    end

    it "emits Requires= and After= when depends_on is configured" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.20
              depends_on: myapp-green.service
        YAML
      accessory = config.accessories.not_nil!["cache"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("cache", accessory)

      output.should contain("Requires=myapp-green.service")
      output.should contain("After=myapp-green.service")
    end

    it "emits Secret= directives from the direct secrets field" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            cache:
              image: docker.io/library/redis:7
              host: 192.168.1.20
              secrets:
                - REDIS_PASSWORD
                - REDIS_TLS_CERT
        YAML
      accessory = config.accessories.not_nil!["cache"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("cache", accessory)

      output.should contain("Secret=REDIS_PASSWORD")
      output.should contain("Secret=REDIS_TLS_CERT")
    end

    it "raises when the accessory image is missing" do
      config = load_config(<<-YAML)
          service: myapp
          image: registry.example.com/myorg/myapp

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            db:
              host: 192.168.1.20
        YAML

      accessory = config.accessories.not_nil!["db"]

      expect_raises(ArgumentError, /Accessory db is missing required image/) do
        Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)
      end
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

    it "creates accessory container files in the output directory" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "db.container")).should be_true
      end
    end
  end
end
