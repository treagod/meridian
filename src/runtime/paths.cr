module Meridian
  module Runtime
    module Paths
      ROOT               = File.join(".local", "state", "meridian")
      SERVICES_DIRECTORY = File.join(ROOT, "services")
      ASSETS_DIRECTORY   = File.join(ROOT, "assets")

      SHARED_PROXY_NETWORK      = "meridian-proxy"
      SHARED_PROXY_NETWORK_FILE = "#{SHARED_PROXY_NETWORK}.network"

      LEGACY_ACTIVE_COLOR_FILE = File.join(Quadlet::DIRECTORY, ".meridian-color")

      def self.service_directory(service : String) : String
        File.join(SERVICES_DIRECTORY, service)
      end

      # Built asset releases for one service. The shared proxy bind-mounts the
      # parent read-only, so every service is reachable through one static mount.
      def self.assets_directory(service : String) : String
        File.join(ASSETS_DIRECTORY, service)
      end

      def self.active_color_file(service : String) : String
        File.join(service_directory(service), "active-color")
      end

      def self.manifest_file(service : String) : String
        File.join(service_directory(service), "manifest.json")
      end

      def self.release_state_file(service : String) : String
        File.join(service_directory(service), "release-state.json")
      end

      def self.lock_file(service : String) : String
        File.join(service_directory(service), "lock")
      end

      def self.lock_metadata_file(service : String) : String
        File.join(lock_file(service), "meta.json")
      end

      def self.audit_log(service : String) : String
        File.join(service_directory(service), "audit.log")
      end

      def self.incremental_oci_directory(service : String) : String
        File.join("/tmp", "meridian-oci", service)
      end
    end
  end
end
