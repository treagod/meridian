require "../spec_helper"

def build_quadlet_generator(content : String = FULL_CONFIG)
  Meridian::Quadlet::Generator.new(load_config(content))
end

def assets_config : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
        proxy:
          host: myapp.example.com

    env:
      clear:
        RAILS_ENV: production
      secret:
        - SECRET_KEY_BASE

    assets:
      host: static.example.com
      command: bin/build-assets
      output_dir: /app/public/assets
      retain_releases: 2
  YAML
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

    it "uses the per-role image when the server role has an image override" do
      config = load_config(<<-YAML)
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

      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["workers"], Meridian::Quadlet::Color::Green)

      output.should contain("Image=ghcr.io/myorg/myapp-worker:latest")
    end

    it "falls back to the global image when the server role has no image override" do
      config = load_config(<<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
          workers:
            hosts:
              - 192.168.1.12
        YAML

      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["workers"], Meridian::Quadlet::Color::Green)

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

  describe "#assets_volume_file" do
    it "includes the [Volume] section header" do
      output = build_quadlet_generator(assets_config).assets_volume_file

      output.should contain("[Volume]")
    end
  end

  describe "#assets_builder_file" do
    it "sets the image to the global app image" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Image=registry.example.com/myorg/myapp")
    end

    it "names the builder container after the service" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("ContainerName=myapp-assets-builder")
    end

    it "mounts the assets volume at /mnt/assets" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Volume=myapp-assets.volume:/mnt/assets")
    end

    it "embeds the command and release_id in the Exec line" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Exec=sh -c \"bin/build-assets && mkdir -p /mnt/assets/20240420120000 && cp -r /app/public/assets/. /mnt/assets/20240420120000/\"")
    end

    it "uses Type=oneshot with RemainAfterExit=yes" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Type=oneshot")
      output.should contain("RemainAfterExit=yes")
    end

    it "includes clear environment variables from config" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Environment=RAILS_ENV=production")
    end

    it "includes secret directives from config" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Secret=SECRET_KEY_BASE,type=env,target=SECRET_KEY_BASE")
    end

    it "raises when assets configuration is absent" do
      config = load_config(MINIMAL_CONFIG)

      expect_raises(ArgumentError, /Missing assets configuration/) do
        Meridian::Quadlet::Generator.new(config).assets_builder_file("20240420120000")
      end
    end
  end

  describe "#assets_server_file" do
    it "uses the caddy image" do
      output = build_quadlet_generator(assets_config).assets_server_file

      output.should contain("Image=caddy:2-alpine")
    end

    it "names the server container after the service" do
      output = build_quadlet_generator(assets_config).assets_server_file

      output.should contain("ContainerName=myapp-assets-server")
    end

    it "mounts the assets volume read-only at /srv/assets" do
      output = build_quadlet_generator(assets_config).assets_server_file

      output.should contain("Volume=myapp-assets.volume:/srv/assets:ro")
    end

    it "mounts the Caddyfile from the home-relative config path" do
      output = build_quadlet_generator(assets_config).assets_server_file

      output.should contain("Volume=%h/.config/containers/myapp-assets-caddy/Caddyfile:/etc/caddy/Caddyfile:ro")
    end

    it "attaches to the service network" do
      output = build_quadlet_generator(assets_config).assets_server_file

      output.should contain("Network=myapp.network")
    end

    it "raises when assets configuration is absent" do
      config = load_config(MINIMAL_CONFIG)

      expect_raises(ArgumentError, /Missing assets configuration/) do
        Meridian::Quadlet::Generator.new(config).assets_server_file
      end
    end
  end

  describe "#assets_caddy_config" do
    it "disables auto_https" do
      output = build_quadlet_generator(assets_config).assets_caddy_config

      output.should contain("auto_https off")
    end

    it "serves from /srv/assets" do
      output = build_quadlet_generator(assets_config).assets_caddy_config

      output.should contain("root * /srv/assets")
      output.should contain("file_server")
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

    it "writes file sync entries to the files/ subdirectory" do
      with_tempdir do |source_dir|
        source_path = File.join(source_dir, "nginx.conf")
        File.write(source_path, "server { listen 80; }")

        with_tempdir do |output_dir|
          generator = build_quadlet_generator(<<-YAML)
            service: myapp
            image: registry.example.com/myorg/myapp

            servers:
              web:
                hosts:
                  - 192.168.1.10

            files:
              - source: #{source_path}
                destination: /home/deploy/nginx.conf
            YAML

          generator.write_to_directory(output_dir, Meridian::Quadlet::Color::Green)

          preview_path = File.join(output_dir, "files", "nginx.conf")
          File.exists?(preview_path).should be_true
          File.read(preview_path).should eq("server { listen 80; }")
        end
      end
    end

    it "renders template files when template is true" do
      with_tempdir do |source_dir|
        source_path = File.join(source_dir, "Caddyfile.ecr")
        File.write(source_path, "handle <%= @config.service %>.example.com")

        with_tempdir do |output_dir|
          generator = build_quadlet_generator(<<-YAML)
            service: myapp
            image: registry.example.com/myorg/myapp

            servers:
              web:
                hosts:
                  - 192.168.1.10

            files:
              - source: #{source_path}
                destination: /home/deploy/Caddyfile
                template: true
            YAML

          generator.write_to_directory(output_dir, Meridian::Quadlet::Color::Green)

          preview_path = File.join(output_dir, "files", "Caddyfile")
          File.read(preview_path).should eq("handle myapp.example.com")
        end
      end
    end

    it "does not create a files/ directory when no files are configured" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        Dir.exists?(File.join(path, "files")).should be_false
      end
    end

    it "creates an assets/ directory with volume, builder, and server files when assets are configured" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "assets", "myapp-assets.volume")).should be_true
        File.exists?(File.join(path, "assets", "myapp-assets-builder.container")).should be_true
        File.exists?(File.join(path, "assets", "myapp-assets-server.container")).should be_true
      end
    end

    it "creates the Caddyfile preview under assets/caddy/" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        caddyfile_path = File.join(path, "assets", "caddy", "Caddyfile")
        File.exists?(caddyfile_path).should be_true
        File.read(caddyfile_path).should contain("auto_https off")
      end
    end

    it "uses a placeholder release ID in the builder preview" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        builder = File.read(File.join(path, "assets", "myapp-assets-builder.container"))
        builder.should contain("<RELEASE_ID>")
      end
    end

    it "does not create an assets/ directory when assets are not configured" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        Dir.exists?(File.join(path, "assets")).should be_false
      end
    end
  end
end
