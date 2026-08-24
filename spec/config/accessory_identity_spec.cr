require "../spec_helper"

# Builds a config declaring one `postgres` accessory from explicit YAML lines,
# so an example can vary a single field without heredoc indentation games.
private def postgres_accessory(
  fields : Array(String),
  service : String = "myapp",
) : Meridian::Config::AccessoryConfig
  content = String.build do |io|
    io << "service: " << service << '\n'
    io << "image: registry.example.com/myorg/" << service << '\n'
    io << "servers:\n  web:\n    hosts:\n      - 192.168.1.10\n"
    io << "accessories:\n  postgres:\n"
    fields.each { |line| io << "    " << line << '\n' }
  end

  value!(load_config(content).accessories)["postgres"]
end

private SHARED_POSTGRES = [
  "image: docker.io/library/postgres:18-alpine",
  "host: server.example.com",
  "network: postgres",
  "volumes:",
  "  - postgres-data:/var/lib/postgresql/data",
]

private def fingerprint(accessory : Meridian::Config::AccessoryConfig) : String
  Meridian::Config::AccessoryIdentity.fingerprint("postgres", accessory)
end

private def definition(accessory : Meridian::Config::AccessoryConfig) : Hash(String, String)
  Meridian::Config::AccessoryIdentity.definition("postgres", accessory)
end

private def shared_postgres_with(replacement : String, at index : Int32) : Array(String)
  fields = SHARED_POSTGRES.dup
  fields[index] = replacement
  fields
end

describe Meridian::Config::AccessoryConfig do
  describe "#network_name" do
    it "returns a bare network name unchanged" do
      accessory = postgres_accessory(["image: docker.io/library/postgres:18", "network: postgres"])

      accessory.network_name.should eq("postgres")
    end

    it "strips the legacy .network suffix" do
      accessory = postgres_accessory(["image: docker.io/library/postgres:18", "network: myapp.network"])

      accessory.network_name.should eq("myapp")
    end

    it "is nil when no network is declared" do
      postgres_accessory(["image: docker.io/library/postgres:18"]).network_name.should be_nil
    end

    it "treats a blank network as absent" do
      postgres_accessory(["image: docker.io/library/postgres:18", "network: \"   \""]).network_name.should be_nil
    end
  end
end

describe Meridian::Config::DeployConfig do
  it "collects accessory networks by logical name, deduplicated and sorted" do
    config = load_config(<<-YAML)
        service: myapp
        image: registry.example.com/myorg/myapp

        servers:
          web:
            hosts:
              - 192.168.1.10

        accessories:
          postgres:
            image: docker.io/library/postgres:18
            network: postgres
          redis:
            image: docker.io/library/redis:7
            network: cache
          search:
            image: docker.io/library/opensearch:2
            network: postgres.network
            ready:
              tcp: 9200
      YAML

    config.accessory_networks.should eq(["cache", "postgres"])
    config.dependent_accessories.keys.sort!.should eq(["postgres", "redis", "search"])
  end

  it "excludes accessories without a network from the dependency set" do
    config = load_config(FULL_CONFIG)

    config.accessory_networks.should be_empty
    config.dependent_accessories.should be_empty
  end

  it "renders generated networks as Quadlet unit references and shared ones raw" do
    config = load_config(MINIMAL_CONFIG)

    config.network_ref("myapp").should eq("myapp.network")
    config.network_ref(Meridian::Runtime::Paths::SHARED_PROXY_NETWORK).should eq("meridian-proxy.network")
    config.network_ref("postgres").should eq("postgres")
  end
end

describe Meridian::Config::AccessoryIdentity do
  describe ".fingerprint" do
    it "is deterministic for the same declaration" do
      accessory = postgres_accessory(SHARED_POSTGRES)

      fingerprint(accessory).should eq(fingerprint(accessory))
      fingerprint(accessory).should eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "ignores the declaring service" do
      freshrss = postgres_accessory(SHARED_POSTGRES, service: "freshrss")
      nextcloud = postgres_accessory(SHARED_POSTGRES, service: "nextcloud")

      fingerprint(freshrss).should eq(fingerprint(nextcloud))
    end

    it "ignores YAML key ordering" do
      reordered = postgres_accessory([
        "volumes:",
        "  - postgres-data:/var/lib/postgresql/data",
        "network: postgres",
        "host: server.example.com",
        "image: docker.io/library/postgres:18-alpine",
      ])

      fingerprint(reordered).should eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "ignores collection ordering" do
      one = postgres_accessory([
        "image: docker.io/library/postgres:18-alpine",
        "host: server.example.com",
        "volumes:",
        "  - postgres-data:/var/lib/postgresql/data",
        "  - postgres-conf:/etc/postgresql",
      ])
      other = postgres_accessory([
        "image: docker.io/library/postgres:18-alpine",
        "host: server.example.com",
        "volumes:",
        "  - postgres-conf:/etc/postgresql",
        "  - postgres-data:/var/lib/postgresql/data",
      ])

      fingerprint(other).should eq(fingerprint(one))
    end

    it "treats the legacy .network suffix as the same network" do
      bare = postgres_accessory(["image: docker.io/library/postgres:18", "network: myapp"])
      suffixed = postgres_accessory(["image: docker.io/library/postgres:18", "network: myapp.network"])

      fingerprint(suffixed).should eq(fingerprint(bare))
    end

    it "treats an explicit readiness block matching the inferred one as identical" do
      inferred = postgres_accessory(["image: docker.io/library/postgres:18-alpine"])
      explicit = postgres_accessory([
        "image: docker.io/library/postgres:18-alpine",
        "ready:",
        "  cmd:",
        "    - pg_isready",
        "    - -q",
      ])

      fingerprint(explicit).should eq(fingerprint(inferred))
    end

    it "differs on image" do
      other = postgres_accessory(shared_postgres_with("image: docker.io/library/postgres:17-alpine", at: 0))

      fingerprint(other).should_not eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "differs on host" do
      other = postgres_accessory(shared_postgres_with("host: other.example.com", at: 1))

      fingerprint(other).should_not eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "differs on network" do
      other = postgres_accessory(shared_postgres_with("network: shared-db", at: 2))

      fingerprint(other).should_not eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "differs on volumes" do
      other = postgres_accessory(shared_postgres_with("  - pgdata:/var/lib/postgresql/data", at: 4))

      fingerprint(other).should_not eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "differs on environment" do
      other = postgres_accessory(SHARED_POSTGRES + ["env:", "  clear:", "    POSTGRES_DB: app"])

      fingerprint(other).should_not eq(fingerprint(postgres_accessory(SHARED_POSTGRES)))
    end

    it "resolves rather than raising for an image with no inferable readiness" do
      accessory = postgres_accessory(["image: docker.io/myorg/custom:1", "host: server.example.com"])

      fingerprint(accessory).should_not be_empty
    end
  end

  describe ".differences" do
    it "reports the fields that differ" do
      current = definition(postgres_accessory(shared_postgres_with("image: docker.io/library/postgres:17-alpine", at: 0)))
      existing = definition(postgres_accessory(SHARED_POSTGRES))

      differences = Meridian::Config::AccessoryIdentity.differences(current, existing)

      differences.map(&.field).should eq(["image"])
      differences.first.current.should eq("docker.io/library/postgres:17-alpine")
      differences.first.existing.should eq("docker.io/library/postgres:18-alpine")
    end

    it "is empty for identical definitions" do
      values = definition(postgres_accessory(SHARED_POSTGRES))

      Meridian::Config::AccessoryIdentity.differences(values, values).should be_empty
    end

    it "skips fields a manifest written by an older Meridian never recorded" do
      values = definition(postgres_accessory(SHARED_POSTGRES))

      Meridian::Config::AccessoryIdentity.differences(values, {} of String => String).should be_empty
    end
  end
end
