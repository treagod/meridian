require "json"

module Meridian
  module Runtime
    struct ProxyRoute
      include JSON::Serializable

      getter name : String
      getter host : String?
      getter path : String?

      def initialize(@name : String, @host : String?, @path : String?)
      end

      def display : String
        host_label = host || "-"
        "#{name}@#{host_label}#{normalized_path}"
      end

      def normalized_path : String
        ServiceManifest.normalize_path(path)
      end
    end

    # One service's reference to a host-local accessory. Two services naming the
    # same accessory on the same host with the same fingerprint are referring to
    # the same container; a differing fingerprint is a conflict.
    struct AccessoryRef
      include JSON::Serializable

      getter host : String?
      # nil on manifests written before schema 2, where the definition was not
      # recorded. Never compares equal, so a stale manifest stays conservative.
      getter fingerprint : String?
      # The canonical field map the fingerprint is derived from, so a conflict
      # can report which fields differ without reading another project's config.
      getter definition : Hash(String, String) = {} of String => String

      def initialize(@host : String?, @fingerprint : String?, @definition = {} of String => String)
      end

      def compatible_with?(other : AccessoryRef) : Bool
        return false unless host == other.host

        !!fingerprint && fingerprint == other.fingerprint
      end
    end

    # Reads both manifest shapes: schema 2 stores accessories as a name to
    # `AccessoryRef` map, schema 1 stored a bare name list.
    module AccessoryRefsConverter
      def self.from_json(pull : JSON::PullParser) : Hash(String, AccessoryRef)
        if pull.kind.begin_array?
          return Array(String).new(pull).to_h { |name| {name, AccessoryRef.new(host: nil, fingerprint: nil)} }
        end

        Hash(String, AccessoryRef).new(pull)
      end

      def self.to_json(value : Hash(String, AccessoryRef), json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    struct ServiceManifest
      include JSON::Serializable

      SCHEMA_VERSION = 2

      getter schema_version : Int32
      getter meridian_version : String? = nil
      getter service : String
      getter proxy_routes : Array(ProxyRoute)
      getter asset_host : String?
      getter ports : Array(String)
      @[JSON::Field(converter: Meridian::Runtime::AccessoryRefsConverter)]
      getter accessories : Hash(String, AccessoryRef)
      getter networks : Array(String)
      getter generated_files : Array(String)
      getter active_color_path : String
      getter release_state_path : String
      getter lock_path : String
      getter audit_path : String
      getter incremental_cache_path : String

      def initialize(
        @service : String,
        @proxy_routes : Array(ProxyRoute),
        @asset_host : String?,
        @ports : Array(String),
        @accessories : Hash(String, AccessoryRef),
        @networks : Array(String),
        @generated_files : Array(String),
        @active_color_path : String,
        @release_state_path : String,
        @lock_path : String,
        @audit_path : String,
        @incremental_cache_path : String,
        @meridian_version : String? = Meridian::VERSION,
      )
        @schema_version = SCHEMA_VERSION
      end

      def self.from_config(config : Config::DeployConfig) : ServiceManifest
        proxy_routes = [] of ProxyRoute

        if proxy = config.servers["web"]?.try(&.proxy)
          proxy_routes << ProxyRoute.new(
            name: config.service,
            host: proxy.host,
            path: proxy.path
          )

          proxy.redirect_hosts.each do |redirect_host|
            proxy_routes << ProxyRoute.new(
              name: "#{config.service}-redirect",
              host: redirect_host,
              path: nil
            )
          end
        end

        asset_host = config.assets.try(&.host)
        if asset_host
          proxy_routes << ProxyRoute.new(
            name: "#{config.service}-assets",
            host: asset_host,
            path: nil
          )
        end

        accessories = accessory_refs(config)
        # Accessory networks are deliberately absent: they are pre-existing
        # shared Podman networks, not networks this service generates, so they
        # must not read as a generated-network collision.
        networks = [config.service]
        networks << Paths::SHARED_PROXY_NETWORK if proxy_routes.present?
        generated_files = generated_files_for(config)

        ServiceManifest.new(
          service: config.service,
          proxy_routes: proxy_routes,
          asset_host: asset_host,
          ports: normalize_ports(config.ports),
          accessories: accessories,
          networks: networks,
          generated_files: generated_files,
          active_color_path: Paths.active_color_file(config.service),
          release_state_path: Paths.release_state_file(config.service),
          lock_path: Paths.lock_file(config.service),
          audit_path: Paths.audit_log(config.service),
          incremental_cache_path: Paths.incremental_oci_directory(config.service)
        )
      end

      private def self.accessory_refs(config : Config::DeployConfig) : Hash(String, AccessoryRef)
        accessories = config.accessories || Config::EMPTY_ACCESSORIES

        accessories.keys.sort!.to_h do |name|
          accessory = accessories[name]
          ref = AccessoryRef.new(
            host: accessory.host.try(&.strip).presence,
            fingerprint: Config::AccessoryIdentity.fingerprint(name, accessory),
            definition: Config::AccessoryIdentity.definition(name, accessory)
          )
          {name, ref}
        end
      end

      # Remote command listing every Meridian service manifest on a host, one
      # JSON document per line. Shared by check, proxy removal, and the
      # accessory lifecycle so they all read the same host-scoped state.
      def self.list_command : Array(String)
        dir = Process.quote_posix(Paths::SERVICES_DIRECTORY)
        [
          "sh", "-lc",
          "if test -d #{dir}; then find #{dir} -mindepth 2 -maxdepth 2 -name manifest.json " \
          "-exec cat {} \\; -exec printf '\\n' \\;; fi",
        ]
      end

      def self.parse_all(output : String) : Array(ServiceManifest)
        output.lines.compact_map do |line|
          text = line.strip
          next if text.empty?

          ServiceManifest.from_json(text)
        end
      end

      def self.normalize_path(path : String?) : String
        value = path.to_s.strip
        return "/" if value.empty?

        value = "/#{value}" unless value.starts_with?("/")
        value = value.rstrip("/")
        value.empty? ? "/" : value
      end

      def self.path_prefixes_overlap?(left : String?, right : String?) : Bool
        a = normalize_path(left)
        b = normalize_path(right)
        return true if a == b || a == "/" || b == "/"

        a.starts_with?("#{b}/") || b.starts_with?("#{a}/")
      end

      def collisions_with(other : ServiceManifest) : Array(String)
        if other.service == service
          differing = ownership_differences(other)
          return [] of String if differing.empty?

          return ["service name #{service} is already registered with different ownership data (#{differing.join(", ")})"]
        end

        collisions = [] of String

        proxy_routes.each do |route|
          other.proxy_routes.each do |other_route|
            next unless route.host == other_route.host
            next unless ServiceManifest.path_prefixes_overlap?(route.path, other_route.path)

            collisions << "proxy route #{route.display} overlaps #{other.service} route #{other_route.display}"
          end
        end

        (ports & other.ports).each do |port|
          collisions << "published host port #{port} is already used by #{other.service}"
        end

        collisions.concat(accessory_collisions_with(other))

        shared_networks = [Paths::SHARED_PROXY_NETWORK]
        ((networks - shared_networks) & (other.networks - shared_networks)).each do |network|
          collisions << "generated network #{network} is already used by #{other.service}"
        end

        (generated_files & other.generated_files).each do |path|
          collisions << "generated file #{path} is already owned by #{other.service}"
        end

        if active_color_path == other.active_color_path
          collisions << "active color path #{active_color_path} is already owned by #{other.service}"
        end

        if release_state_path == other.release_state_path
          collisions << "release state path #{release_state_path} is already owned by #{other.service}"
        end

        if lock_path == other.lock_path
          collisions << "lock path #{lock_path} is already owned by #{other.service}"
        end

        collisions
      end

      # Accessory names are intentionally shared: the same name, host, and
      # definition mean the same host resource. Only a differing definition on
      # the same host is a conflict, and a different host is a different
      # resource entirely.
      def accessory_collisions_with(other : ServiceManifest) : Array(String)
        accessories.compact_map do |name, ref|
          other_ref = other.accessories[name]?
          next if other_ref.nil? || ref.host != other_ref.host
          next if ref.compatible_with?(other_ref)

          "accessory #{name} on #{ref.host || "-"} conflicts with the definition registered by #{other.service}"
        end
      end

      # Services referencing the same accessory as a compatible shared resource.
      def services_sharing(name : String, others : Array(ServiceManifest)) : Array(String)
        partition_accessory(name, others).first
      end

      # Services claiming the same accessory on the same host with a different
      # definition. One of them would have to overwrite the other.
      def services_conflicting(name : String, others : Array(ServiceManifest)) : Array(String)
        partition_accessory(name, others).last
      end

      private def partition_accessory(name : String, others : Array(ServiceManifest)) : {Array(String), Array(String)}
        ref = accessories[name]?
        return {[] of String, [] of String} unless ref

        shared = [] of String
        conflicting = [] of String

        others.each do |other|
          next if other.service == service

          other_ref = other.accessories[name]?
          next if other_ref.nil? || ref.host != other_ref.host

          (ref.compatible_with?(other_ref) ? shared : conflicting) << other.service
        end

        {shared.uniq!.sort!, conflicting.uniq!.sort!}
      end

      # Identity only. State paths, generated_files and accessory refs drift
      # between meridian versions, so comparing them reports drift as a conflict.
      private def ownership_differences(other : ServiceManifest) : Array(String)
        differing = [] of String

        differing << "proxy_routes" unless proxy_routes.map(&.display).sort! == other.proxy_routes.map(&.display).sort!
        differing << "asset_host" unless asset_host == other.asset_host
        differing << "ports" unless ports == other.ports
        differing << "accessories" unless accessories.keys.sort! == other.accessories.keys.sort!
        differing << "networks" unless networks.sort == other.networks.sort

        differing
      end

      private def self.generated_files_for(config : Config::DeployConfig) : Array(String)
        files = [
          File.join(Quadlet::DIRECTORY, "#{config.service}.network"),
          Paths.manifest_file(config.service),
        ]
        if config.servers.values.any? { |server| server.managed? && server.proxy }
          files << Paths.active_color_file(config.service)
        end

        config.servers.each do |role, server|
          next unless server.managed?

          if server.proxy
            files << File.join(Quadlet::DIRECTORY, "#{config.service}-blue.container")
            files << File.join(Quadlet::DIRECTORY, "#{config.service}-green.container")
          else
            files << File.join(Quadlet::DIRECTORY, "#{config.service}-#{role}.container")
          end
        end

        if config.assets
          files << File.join(Quadlet::DIRECTORY, "#{config.service}-assets-builder.container")
        end

        files.uniq!
        files.sort!
        files
      end

      private def self.normalize_ports(ports : Array(String)) : Array(String)
        ports.map { |port| normalize_port(port) }.reject(&.empty?).uniq!.sort!
      end

      private def self.normalize_port(port : String) : String
        value = port.strip
        return "" if value.empty?

        parts = value.split(":")
        host_port =
          case parts.size
          when 1
            parts[0]
          when 2
            parts[0]
          else
            parts[-2]
          end

        host_port.split("/").first.strip
      end
    end
  end
end
