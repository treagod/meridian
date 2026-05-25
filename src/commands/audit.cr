module Meridian
  module Commands
    # Prints recent Meridian audit entries recorded on each host. Read-only:
    # it never mutates state and never acquires the deploy lock.
    class Audit < Base
      DEFAULT_LIMIT = 20

      def run(host : String?, limit : Int32 = DEFAULT_LIMIT) : Int32
        targets = host ? [validated_host(host)] : audit_hosts
        targets.each_with_index do |target, index|
          @output.puts if index > 0
          @output.puts "[#{target}]"
          entries = audit_logger.recent(target, limit)
          if entries.empty?
            @output.puts "  (no audit entries)"
          else
            entries.each { |entry| @output.puts "  #{entry.to_line}" }
          end
        end
        0
      rescue ex : SSH::ConnectionError
        raise ArgumentError.new(ex.message || "Failed to read audit log")
      end

      # Server hosts plus accessory hosts, so accessory audit entries are
      # visible without naming the accessory host explicitly.
      private def audit_hosts : Array(String)
        hosts = all_hosts
        @config.accessories.try &.each_value do |accessory|
          candidate = accessory.host.to_s.strip
          hosts << candidate unless candidate.empty? || hosts.includes?(candidate)
        end
        hosts
      end

      private def validated_host(host : String) : String
        return host if audit_hosts.includes?(host)

        raise ArgumentError.new("Unknown host: #{host}. Valid hosts: #{audit_hosts.join(", ")}")
      end
    end
  end
end
