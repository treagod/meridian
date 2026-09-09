require "../spec_helper"

private def manifest_config(
  service : String,
  accessory_host : String = "server.example.com",
  image : String = "docker.io/library/postgres:18-alpine",
  network : String = "postgres",
  volume : String = "postgres-data:/var/lib/postgresql/data",
  accessory : String = "postgres",
) : Meridian::Config::DeployConfig
  load_config(<<-YAML)
      service: #{service}
      image: registry.example.com/myorg/#{service}

      servers:
        web:
          hosts:
            - 192.168.1.10

      accessories:
        #{accessory}:
          image: #{image}
          host: #{accessory_host}
          network: #{network}
          volumes:
            - #{volume}
    YAML
end

private def manifest_for(**options) : Meridian::Runtime::ServiceManifest
  Meridian::Runtime::ServiceManifest.from_config(manifest_config(**options))
end

private def accessory_collisions(
  left : Meridian::Runtime::ServiceManifest,
  right : Meridian::Runtime::ServiceManifest,
) : Array(String)
  left.accessory_collisions_with(right)
end

describe Meridian::Runtime::ServiceManifest do
  describe "accessory identity" do
    it "records host and fingerprint per accessory" do
      manifest = manifest_for(service: "freshrss")
      ref = manifest.accessories["postgres"]

      ref.host.should eq("server.example.com")
      value!(ref.fingerprint).should_not be_empty
      ref.definition["image"].should eq("docker.io/library/postgres:18-alpine")
      ref.definition["network"].should eq("postgres")
    end

    it "treats the same name, host, and definition as one shared resource" do
      freshrss = manifest_for(service: "freshrss")
      nextcloud = manifest_for(service: "nextcloud")

      accessory_collisions(nextcloud, freshrss).should be_empty
      nextcloud.collisions_with(freshrss).should be_empty
    end

    it "conflicts on a different image" do
      freshrss = manifest_for(service: "freshrss")
      nextcloud = manifest_for(service: "nextcloud", image: "docker.io/library/postgres:17-alpine")

      collisions = accessory_collisions(nextcloud, freshrss)

      collisions.size.should eq(1)
      collisions.first.should contain("accessory postgres")
      collisions.first.should contain("freshrss")
    end

    it "conflicts on a different volume configuration" do
      freshrss = manifest_for(service: "freshrss")
      nextcloud = manifest_for(service: "nextcloud", volume: "pgdata:/var/lib/postgresql/data")

      accessory_collisions(nextcloud, freshrss).size.should eq(1)
    end

    it "conflicts on a different network" do
      freshrss = manifest_for(service: "freshrss")
      nextcloud = manifest_for(service: "nextcloud", network: "shared-db")

      accessory_collisions(nextcloud, freshrss).size.should eq(1)
    end

    it "does not collide when the same name is pinned to different hosts" do
      freshrss = manifest_for(service: "freshrss", accessory_host: "one.example.com")
      nextcloud = manifest_for(service: "nextcloud", accessory_host: "two.example.com")

      accessory_collisions(nextcloud, freshrss).should be_empty
      nextcloud.collisions_with(freshrss).should be_empty
    end

    it "reports which services share a compatible accessory" do
      freshrss = manifest_for(service: "freshrss")
      vaultwarden = manifest_for(service: "vaultwarden")
      nextcloud = manifest_for(service: "nextcloud")

      nextcloud.services_sharing("postgres", [freshrss, vaultwarden]).should eq(["freshrss", "vaultwarden"])
      nextcloud.services_conflicting("postgres", [freshrss, vaultwarden]).should be_empty
    end

    it "reports which services conflict" do
      freshrss = manifest_for(service: "freshrss", image: "docker.io/library/postgres:17-alpine")
      nextcloud = manifest_for(service: "nextcloud")

      nextcloud.services_conflicting("postgres", [freshrss]).should eq(["freshrss"])
      nextcloud.services_sharing("postgres", [freshrss]).should be_empty
    end

    it "keeps accessory networks out of the generated network set" do
      manifest = manifest_for(service: "nextcloud")

      manifest.networks.should_not contain("postgres")
      manifest.networks.should contain("nextcloud")
    end
  end

  describe "schema compatibility" do
    it "declares schema version 2" do
      manifest_for(service: "freshrss").schema_version.should eq(2)
    end

    it "records the Meridian version that wrote the manifest" do
      manifest = manifest_for(service: "freshrss")

      manifest.meridian_version.should eq(Meridian::VERSION)
      Meridian::Runtime::ServiceManifest.from_json(manifest.to_json).meridian_version.should eq(Meridian::VERSION)
    end

    it "reads schema 2 manifests written before the Meridian version was recorded" do
      manifest = manifest_for(service: "freshrss")
      json = manifest.to_json.sub(%(,"meridian_version":"#{Meridian::VERSION}"), "")

      Meridian::Runtime::ServiceManifest.from_json(json).meridian_version.should be_nil
    end

    it "round-trips through JSON" do
      manifest = manifest_for(service: "freshrss")

      parsed = Meridian::Runtime::ServiceManifest.from_json(manifest.to_json)

      parsed.accessories["postgres"].fingerprint.should eq(manifest.accessories["postgres"].fingerprint)
      parsed.accessories["postgres"].definition.should eq(manifest.accessories["postgres"].definition)
    end

    it "serializes to a single line, as the remote listing contract requires" do
      manifest_for(service: "freshrss").to_json.lines.size.should eq(1)
    end

    # A schema-1 manifest recorded accessory names only. It still parses, but an
    # unknown definition never compares equal, so it stays a conflict until that
    # service redeploys - exactly the pre-shared-accessory behaviour.
    it "parses a schema 1 manifest and treats its accessories conservatively" do
      legacy = Meridian::Runtime::ServiceManifest.from_json(<<-JSON)
          {
            "schema_version": 1,
            "service": "freshrss",
            "proxy_routes": [],
            "asset_host": null,
            "ports": [],
            "accessories": ["postgres"],
            "networks": ["freshrss"],
            "generated_files": [],
            "active_color_path": ".local/state/meridian/services/freshrss/active-color",
            "release_state_path": ".local/state/meridian/services/freshrss/release-state.json",
            "lock_path": ".local/state/meridian/services/freshrss/lock",
            "audit_path": ".local/state/meridian/services/freshrss/audit.log",
            "incremental_cache_path": "/tmp/meridian-oci/freshrss"
          }
        JSON

      legacy.accessories.keys.should eq(["postgres"])
      legacy.meridian_version.should be_nil
      legacy.accessories["postgres"].fingerprint.should be_nil
      legacy.accessories["postgres"].definition.should be_empty

      # nil host on the legacy side, so it reads as a different resource rather
      # than a false conflict against a host-pinned accessory.
      nextcloud = manifest_for(service: "nextcloud")
      accessory_collisions(nextcloud, legacy).should be_empty

      # Same host on both sides and no recorded definition: conservative conflict.
      unpinned = Meridian::Runtime::ServiceManifest.from_json(
        manifest_for(service: "nextcloud", accessory_host: "").to_json
      )
      accessory_collisions(unpinned, legacy).size.should eq(1)
    end
  end

  describe "same-service ownership" do
    it "does not collide with its own manifest written by an older schema" do
      current = manifest_for(service: "freshrss")
      legacy = Meridian::Runtime::ServiceManifest.from_json(<<-JSON)
          {
            "schema_version": 1,
            "service": "freshrss",
            "proxy_routes": [],
            "asset_host": null,
            "ports": [],
            "accessories": ["postgres"],
            "networks": ["freshrss"],
            "generated_files": [".config/containers/systemd/freshrss-old.container"],
            "active_color_path": ".local/state/meridian/services/freshrss/active-color",
            "release_state_path": ".local/state/meridian/services/freshrss/release-state.json",
            "lock_path": ".local/state/meridian/services/freshrss/lock",
            "audit_path": ".local/state/meridian/services/freshrss/audit.log",
            "incremental_cache_path": "/tmp/meridian-oci/freshrss"
          }
        JSON

      current.collisions_with(legacy).should be_empty
    end

    it "does not treat a different Meridian version as an ownership conflict" do
      current = manifest_for(service: "freshrss")
      older = Meridian::Runtime::ServiceManifest.from_json(
        current.to_json.sub(%("meridian_version":"#{Meridian::VERSION}"), %("meridian_version":"0.0.1"))
      )

      current.collisions_with(older).should be_empty
    end

    it "collides when the same name describes a different deployment" do
      current = manifest_for(service: "freshrss")
      other = Meridian::Runtime::ServiceManifest.from_json(
        current.to_json.sub(%("accessories":{"postgres"), %("accessories":{"mysql"))
      )

      collisions = current.collisions_with(other)

      collisions.size.should eq(1)
      collisions.first.should contain("accessories")
    end
  end

  describe "existing collision rules" do
    it "still reports overlapping proxy routes" do
      left = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
          service: one
          image: registry.example.com/myorg/one
          servers:
            web:
              hosts:
                - 192.168.1.10
              proxy:
                host: app.example.com
        YAML
      right = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
          service: two
          image: registry.example.com/myorg/two
          servers:
            web:
              hosts:
                - 192.168.1.11
              proxy:
                host: app.example.com
        YAML

      left.collisions_with(right).any?(&.includes?("proxy route")).should be_true
    end

    it "reports overlapping hostless routes but permits distinct prefixes" do
      config = ->(service : String, path : String) do
        load_config(<<-YAML)
          service: #{service}
          image: example.com/#{service}
          servers:
            web:
              hosts: [192.168.1.10]
              proxy:
                path: #{path}
          YAML
      end
      root = Meridian::Runtime::ServiceManifest.from_config(config.call("one", "/"))
      blog = Meridian::Runtime::ServiceManifest.from_config(config.call("two", "/blog"))
      shop = Meridian::Runtime::ServiceManifest.from_config(config.call("three", "/shop"))

      root.collisions_with(blog).any?(&.includes?("proxy route")).should be_true
      blog.collisions_with(shop).any?(&.includes?("proxy route")).should be_false
    end

    it "still reports published host port overlap" do
      left = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
          service: one
          image: registry.example.com/myorg/one
          servers:
            web:
              hosts:
                - 192.168.1.10
          ports:
            - "8080:80"
        YAML
      right = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
          service: two
          image: registry.example.com/myorg/two
          servers:
            web:
              hosts:
                - 192.168.1.10
          ports:
            - "8080:3000"
        YAML

      left.collisions_with(right).any?(&.includes?("published host port 8080")).should be_true
    end
  end

  describe ".list_command" do
    it "reads every manifest under the services directory" do
      command = Meridian::Runtime::ServiceManifest.list_command.join(" ")

      command.should contain(".local/state/meridian/services")
      command.should contain("-name manifest.json")
    end
  end

  describe ".parse_all" do
    it "skips blank lines" do
      manifest = manifest_for(service: "freshrss")

      parsed = Meridian::Runtime::ServiceManifest.parse_all("\n#{manifest.to_json}\n\n")

      parsed.map(&.service).should eq(["freshrss"])
    end
  end

  describe "#generated_files" do
    it "claims only the builder Quadlet for a service with assets" do
      manifest = Meridian::Runtime::ServiceManifest.from_config(load_config(<<-YAML))
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
        YAML

      manifest.generated_files.select(&.includes?("assets"))
        .should eq([".config/containers/systemd/myapp-assets-builder.container"])
    end
  end
end
