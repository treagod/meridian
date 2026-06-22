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
    end
  end
end
