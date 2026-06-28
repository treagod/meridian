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

    struct ServiceManifest
      include JSON::Serializable

      getter schema_version : Int32
      getter service : String
      getter proxy_routes : Array(ProxyRoute)
      getter asset_host : String?
      getter ports : Array(String)
      getter accessories : Array(String)
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
        @accessories : Array(String),
        @networks : Array(String),
        @generated_files : Array(String),
        @active_color_path : String,
        @release_state_path : String,
        @lock_path : String,
        @audit_path : String,
        @incremental_cache_path : String,
      )
        @schema_version = 1
      end

      def self.from_config(config : Config::DeployConfig) : ServiceManifest
        proxy_routes = [] of ProxyRoute

        if proxy = config.servers["web"]?.try(&.proxy)
          proxy_routes << ProxyRoute.new(
            name: config.service,
            host: proxy.host,
            path: proxy.path
          )
        end

        asset_host = config.assets.try(&.host)
        if asset_host
          proxy_routes << ProxyRoute.new(
            name: "#{config.service}-assets",
            host: asset_host,
            path: nil
          )
        end

        accessories = (config.accessories || {} of String => Config::AccessoryConfig).keys.sort!
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
          return [] of String if same_owner?(other)

          return ["service name #{service} is already registered with different ownership data"]
        end

        collisions = [] of String

        proxy_routes.each do |route|
          other.proxy_routes.each do |other_route|
            next unless route.host && other_route.host
            next unless route.host == other_route.host
            next unless ServiceManifest.path_prefixes_overlap?(route.path, other_route.path)

            collisions << "proxy route #{route.display} overlaps #{other.service} route #{other_route.display}"
          end
        end

        (ports & other.ports).each do |port|
          collisions << "published host port #{port} is already used by #{other.service}"
        end

        (accessories & other.accessories).each do |name|
          collisions << "accessory name #{name} is already used by #{other.service}"
        end

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

      private def same_owner?(other : ServiceManifest) : Bool
        proxy_routes.map(&.display).sort! == other.proxy_routes.map(&.display).sort! &&
          asset_host == other.asset_host &&
          ports == other.ports &&
          accessories == other.accessories &&
          networks == other.networks &&
          generated_files == other.generated_files &&
          active_color_path == other.active_color_path &&
          release_state_path == other.release_state_path &&
          lock_path == other.lock_path
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
          files << File.join(Quadlet::DIRECTORY, "#{config.service}-assets.volume")
          files << File.join(Quadlet::DIRECTORY, "#{config.service}-assets-builder.container")
          files << File.join(Quadlet::DIRECTORY, "#{config.service}-assets-server.container")
          files << File.join(".config", "containers", "#{config.service}-assets-caddy", "Caddyfile")
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
