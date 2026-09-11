require "../spec_helper"

def build_quadlet_generator(content : String = FULL_CONFIG)
  Meridian::Quadlet::Generator.new(load_config(content))
end

def proxied_config_without_root_proxy : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
        proxy:
          host: myapp.example.com
    YAML
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

def assets_config_without_compression : String
  <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
        proxy:
          host: myapp.example.com

    assets:
      host: static.example.com
      command: bin/build-assets
      output_dir: /app/public/assets
      retain_releases: 2
      compression: false
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

# Nextcloud declaring a `postgres` accessory on a shared Podman network - the
# canonical shared-accessory shape.
def shared_network_config(proxied : Bool = false) : String
  # Interpolated text is not dedented with the heredoc, so it carries the final
  # indentation: `proxy:` is a sibling of `hosts:` under `web:`.
  proxy_block = proxied ? "\n    proxy:\n      host: nextcloud.example.com" : ""

  <<-YAML
    service: nextcloud
    image: registry.example.com/myorg/nextcloud

    servers:
      web:
        hosts:
          - 192.168.1.10#{proxy_block}

    accessories:
      postgres:
        image: docker.io/library/postgres:18-alpine
        host: 192.168.1.10
        network: postgres
        volumes:
          - postgres-data:/var/lib/postgresql/data
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

    it "uses the explicit image argument over any configured image" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(
        config.servers["web"],
        Meridian::Quadlet::Color::Green,
        image: "registry.example.com/myorg/myapp:previous"
      )

      output.should contain("Image=registry.example.com/myorg/myapp:previous")
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

    it "sets a non-proxied container name from its role" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).role_container_file("workers", config.servers["workers"])

      output.should contain("Description=myapp (workers)")
      output.should contain("ContainerName=myapp-workers")
      output.should_not contain("Network=meridian-proxy.network")
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

    it "declares systemd dependencies on accessories that share the service network" do
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
              ready:
                tcp: 6379
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Wants=cache.service")
      output.should contain("After=cache.service")
    end

    it "omits accessory dependencies when no accessory declares a network" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should_not contain("Wants=db.service")
    end

    it "declares systemd dependencies on accessories using a shared network" do
      config = load_config(shared_network_config)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.should contain("Wants=postgres.service")
      output.should contain("After=postgres.service")
    end

    it "joins the accessory network alongside the private service network" do
      config = load_config(shared_network_config)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      # `nextcloud.network` is a Quadlet unit Meridian generates; `postgres` is a
      # pre-existing Podman network referenced by its bare name.
      output.should contain("Network=nextcloud.network")
      output.should contain("Network=postgres")
      output.should_not contain("Network=postgres.network")
    end

    it "keeps the shared proxy network for proxied roles" do
      config = load_config(shared_network_config(proxied: true))
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      network_lines = output.lines.select(&.starts_with?("Network="))

      network_lines.should eq(["Network=nextcloud.network", "Network=meridian-proxy.network", "Network=postgres"])
    end

    it "emits each accessory network once when several accessories share it" do
      config = load_config(<<-YAML)
          service: nextcloud
          image: registry.example.com/myorg/nextcloud

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            postgres:
              image: docker.io/library/postgres:18-alpine
              host: 192.168.1.10
              network: postgres
            pgbouncer:
              image: docker.io/edoburu/pgbouncer:1
              host: 192.168.1.10
              network: postgres
              ready:
                tcp: 6432
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.lines.count("Network=postgres").should eq(1)
    end

    it "joins every distinct accessory network" do
      config = load_config(<<-YAML)
          service: nextcloud
          image: registry.example.com/myorg/nextcloud

          servers:
            web:
              hosts:
                - 192.168.1.10

          accessories:
            postgres:
              image: docker.io/library/postgres:18-alpine
              host: 192.168.1.10
              network: postgres
            redis:
              image: docker.io/library/redis:7
              host: 192.168.1.10
              network: cache
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.lines.select(&.starts_with?("Network=")).should eq([
        "Network=nextcloud.network",
        "Network=cache",
        "Network=postgres",
      ])
    end

    it "does not duplicate the private service network when an accessory names it" do
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
              host: 192.168.1.10
              network: myapp
        YAML
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Green)

      output.lines.select(&.starts_with?("Network=")).should eq(["Network=myapp.network"])
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

    it "attaches proxied app containers to the shared proxy network" do
      config = load_config(FULL_CONFIG)
      output = Meridian::Quadlet::Generator.new(config).container_file(config.servers["web"], Meridian::Quadlet::Color::Blue)

      output.should contain("Network=myapp.network")
      output.should contain("Network=meridian-proxy.network")
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

  describe "#proxy_network_file" do
    it "names the shared proxy network" do
      output = build_quadlet_generator.proxy_network_file

      output.should contain("NetworkName=meridian-proxy")
    end
  end

  describe "#proxy_container_file" do
    it "renders every configured Caddy container setting" do
      config = load_config(<<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: app.example.com
        proxy:
          image: example.com/custom-caddy:2.11.4
          http_port: 8080
          https_port: 8443
          data_dir: /srv/meridian-caddy
        YAML
      output = Meridian::Quadlet::Generator.new(config).proxy_container_file

      output.should eq(<<-QUADLET)
        [Container]
        Image=example.com/custom-caddy:2.11.4
        ContainerName=meridian-caddy
        AddCapability=NET_BIND_SERVICE
        Network=meridian-proxy.network
        PublishPort=8080:80
        PublishPort=8443:443
        Volume=/srv/meridian-caddy:/data
        Volume=%h/.config/containers/meridian-caddy:/config
        Volume=%h/.local/state/meridian/assets:/srv/assets:ro
        Exec=caddy run --config /config/Caddyfile --adapter caddyfile

        [Service]
        Restart=always

        [Install]
        WantedBy=default.target

        QUADLET
    end

    it "renders the complete pinned defaults when the root proxy block is omitted" do
      output = build_quadlet_generator(proxied_config_without_root_proxy).proxy_container_file

      output.should eq(<<-QUADLET)
        [Container]
        Image=docker.io/library/caddy:2.11.4-alpine
        ContainerName=meridian-caddy
        AddCapability=NET_BIND_SERVICE
        Network=meridian-proxy.network
        PublishPort=80:80
        PublishPort=443:443
        Volume=%h/.local/share/meridian-caddy:/data
        Volume=%h/.config/containers/meridian-caddy:/config
        Volume=%h/.local/state/meridian/assets:/srv/assets:ro
        Exec=caddy run --config /config/Caddyfile --adapter caddyfile

        [Service]
        Restart=always

        [Install]
        WantedBy=default.target

        QUADLET
    end
  end

  describe "#proxy_caddyfile" do
    it "imports only completed route fragments through the private admin socket" do
      build_quadlet_generator.proxy_caddyfile.should eq(
        "{\n\tadmin unix//config/admin.sock\n}\n\nimport /config/routes/*.caddy\n"
      )
    end
  end

  describe "#proxy_route" do
    it "renders HTTPS, path stripping, the target, and the drain delay" do
      config = load_config(<<-YAML)
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: example.com
              ssl: true
              path: /blog/
        proxy:
          drain_timeout: 42
        YAML
      proxy = config.servers["web"].proxy || raise "Expected proxy"
      route = Meridian::Quadlet::Generator.new(config).proxy_route(proxy, "myapp-blue:3000")

      route.should eq(
        "example.com/blog, example.com/blog/* {\n" \
        "\turi strip_prefix /blog\n" \
        "\treverse_proxy myapp-blue:3000 {\n" \
        "\t\tstream_close_delay 42s\n" \
        "\t}\n" \
        "}\n"
      )
    end

    it "renders hostless routes as HTTP catch-alls" do
      config = load_config(<<-YAML)
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              path: /app
        YAML
      proxy = config.servers["web"].proxy || raise "Expected proxy"
      route = Meridian::Quadlet::Generator.new(config).proxy_route(proxy, "myapp-green:3000")

      route.should eq(
        ":80/app, :80/app/* {\n" \
        "\turi strip_prefix /app\n" \
        "\treverse_proxy myapp-green:3000 {\n" \
        "\t\tstream_close_delay 300s\n" \
        "\t}\n" \
        "}\n"
      )
    end

    it "renders maintenance as a 503 response" do
      config = load_config(<<-YAML)
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: example.com
        YAML
      proxy = config.servers["web"].proxy || raise "Expected proxy"

      Meridian::Quadlet::Generator.new(config).proxy_maintenance_route(proxy).should eq(
        "http://example.com {\n\trespond 503\n}\n"
      )
    end

    it "serves assets from the shared proxy's own mount, with the web route's TLS setting" do
      config = load_config(<<-YAML)
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: example.com
              ssl: true
        assets:
          host: static.example.com
          command: bin/build-assets
          output_dir: /app/public/assets
        YAML

      Meridian::Quadlet::Generator.new(config).proxy_asset_route.should eq(
        "static.example.com {\n" \
        "\troot * /srv/assets/myapp\n" \
        "\ttry_files /current{path} /previous{path}\n" \
        "\theader Access-Control-Allow-Origin \"*\"\n" \
        "\theader Cache-Control \"public, max-age=31536000, immutable\"\n" \
        "\tencode zstd gzip\n" \
        "\tfile_server\n" \
        "}\n"
      )
    end

    it "drops compression from the asset route when disabled" do
      config = load_config(<<-YAML)
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts: [192.168.1.10]
            proxy:
              host: example.com
        assets:
          host: static.example.com
          command: bin/build-assets
          output_dir: /app/public/assets
          compression: false
        YAML

      output = Meridian::Quadlet::Generator.new(config).proxy_asset_route
      output.should start_with("http://static.example.com {\n")
      output.should_not contain("encode")
      output.should contain("file_server")
    end
  end

  describe "#accessory_container_file" do
    it "names the accessory container after the accessory key" do
      config = load_config(FULL_CONFIG)
      accessory = value!(config.accessories)["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("ContainerName=db")
      output.should contain("Image=docker.io/library/postgres:16")
    end

    it "publishes the configured port and mounts volumes" do
      config = load_config(FULL_CONFIG)
      accessory = value!(config.accessories)["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("PublishPort=5432:5432")
      output.should contain("Volume=pgdata:/var/lib/postgresql/data")
    end

    it "includes clear environment variables and command overrides" do
      config = load_config(accessory_generator_config)
      accessory = value!(config.accessories)["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("Environment=POSTGRES_DB=meridian")
      output.should contain("Exec=postgres -c shared_buffers=256MB")
    end

    it "emits Secret= directives for each accessory env.secret name injected as env vars" do
      config = load_config(FULL_CONFIG)
      accessory = value!(config.accessories)["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("Secret=POSTGRES_PASSWORD,type=env,target=POSTGRES_PASSWORD")
    end

    it "includes a [Unit] section with a description" do
      config = load_config(FULL_CONFIG)
      accessory = value!(config.accessories)["db"]
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
      accessory = value!(config.accessories)["cache"]
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
      accessory = value!(config.accessories)["cache"]
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
      accessory = value!(config.accessories)["cache"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("cache", accessory)

      output.should contain("Secret=REDIS_PASSWORD")
      output.should contain("Secret=REDIS_TLS_CERT")
    end

    it "renders a Podman healthcheck from an inferred cmd readiness probe" do
      config = load_config(FULL_CONFIG)
      accessory = value!(config.accessories)["db"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)

      output.should contain("HealthCmd=pg_isready -q")
      output.should contain("HealthInterval=1s")
      output.should contain("HealthRetries=30")
      output.should contain("HealthStartPeriod=5s")
    end

    it "omits HealthCmd for a tcp readiness probe" do
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
              ready:
                tcp: 6379
        YAML
      accessory = value!(config.accessories)["cache"]
      output = Meridian::Quadlet::Generator.new(config).accessory_container_file("cache", accessory)

      output.should_not contain("HealthCmd=")
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

      accessory = value!(config.accessories)["db"]

      expect_raises(ArgumentError, /Accessory db is missing required image/) do
        Meridian::Quadlet::Generator.new(config).accessory_container_file("db", accessory)
      end
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

    it "mounts the service asset directory at /mnt/assets, chowned to the builder's UID" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Volume=%h/.local/state/meridian/assets/myapp:/mnt/assets:U")
    end

    it "embeds the command, release_id, and current symlink in the Exec line" do
      output = build_quadlet_generator(assets_config).assets_builder_file("20240420120000")

      output.should contain("Exec=sh -c \"bin/build-assets && mkdir -p /mnt/assets/20240420120000 && cp -r /app/public/assets/. /mnt/assets/20240420120000/ && ln -snf 20240420120000 /mnt/assets/current\"")
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

  describe "#write_to_directory" do
    it "creates a .container file in the output directory" do
      with_tempdir do |path|
        build_quadlet_generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "myapp-green.container")).should be_true
        File.exists?(File.join(path, "myapp-workers.container")).should be_true
        File.read(File.join(path, "myapp-workers.container")).should contain("ContainerName=myapp-workers")
      end
    end

    it "previews a role-named file when the web role is not proxied" do
      generator = build_quadlet_generator(<<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10
        YAML

      with_tempdir do |path|
        generator.write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.exists?(File.join(path, "myapp-web.container")).should be_true
        File.exists?(File.join(path, "myapp-green.container")).should be_false
      end
    end

    it "reports role-named and color Quadlets in the service manifest" do
      manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(FULL_CONFIG))

      manifest.generated_files.should contain(".config/containers/systemd/myapp-blue.container")
      manifest.generated_files.should contain(".config/containers/systemd/myapp-green.container")
      manifest.generated_files.should contain(".config/containers/systemd/myapp-workers.container")
    end

    it "does not report active-color or color Quadlets for a non-proxied service" do
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
      manifest = Meridian::Runtime::ServiceManifest.from_config(config)

      manifest.generated_files.should contain(".config/containers/systemd/myapp-workers.container")
      manifest.generated_files.should_not contain(".config/containers/systemd/myapp-blue.container")
      manifest.generated_files.should_not contain(".config/containers/systemd/myapp-green.container")
      manifest.generated_files.should_not contain(".local/state/meridian/services/myapp/active-color")
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

        File.exists?(File.join(path, "meridian-caddy.container")).should be_true
        File.exists?(File.join(path, "caddy", "Caddyfile")).should be_true
      end
    end

    it "creates a proxy .container file when a role is proxied and the root proxy block is omitted" do
      with_tempdir do |path|
        build_quadlet_generator(proxied_config_without_root_proxy).write_to_directory(path, Meridian::Quadlet::Color::Green)

        proxy_path = File.join(path, "meridian-caddy.container")
        File.exists?(proxy_path).should be_true
        File.read(proxy_path).should contain("Image=docker.io/library/caddy:2.11.4-alpine")
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

    it "creates an assets/ directory holding only the builder when assets are configured" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        Dir.children(File.join(path, "assets")).should eq(["myapp-assets-builder.container"])
      end
    end

    it "previews the asset route alongside the shared proxy's other routes" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        route = File.read(File.join(path, "caddy", "routes", "myapp-assets.caddy"))
        route.should contain("root * /srv/assets/myapp")
        route.should contain("try_files /current{path} /previous{path}")
        route.should contain("file_server")
        route.should_not contain("reverse_proxy")
      end
    end

    it "mounts the shared asset directory into the proxy preview" do
      with_tempdir do |path|
        build_quadlet_generator(assets_config).write_to_directory(path, Meridian::Quadlet::Color::Green)

        File.read(File.join(path, "meridian-caddy.container"))
          .should contain("Volume=%h/.local/state/meridian/assets:/srv/assets:ro")
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
