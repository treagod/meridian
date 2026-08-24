module Meridian
  module Runtime
    module ServiceNetwork
      def self.name(service : String) : String
        service
      end

      def self.file(service : String) : String
        "#{service}.network"
      end

      def self.unit(service : String) : String
        "#{service}-network.service"
      end

      def self.exists_command(service : String) : Array(String)
        ["podman", "network", "exists", name(service)]
      end

      def self.start_command(service : String) : Array(String)
        ["systemctl", "--user", "start", unit(service)]
      end

      def self.missing_message(service : String, host : String, command : String) : String
        "Service network #{name(service)} is not available on #{host}. Run `meridian setup` before `#{command}`."
      end

      # Custom accessory networks are shared Podman networks rather than
      # generated Quadlet units, so `meridian accessory start` materializes
      # them instead of `meridian setup`.
      def self.network_exists_command(network : String) : Array(String)
        ["podman", "network", "exists", network]
      end

      def self.missing_accessory_network_message(network : String, host : String, accessory : String) : String
        "Required network '#{network}' is not available on #{host}.\n\n" \
        "Start the accessory first:\n\n" \
        "  meridian accessory start #{accessory}\n\n" \
        "Then run `meridian check` to verify the server before deploying."
      end
    end
  end
end
