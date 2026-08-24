require "digest/sha256"

module Meridian
  module Config
    # Canonical identity of an accessory as a host resource.
    #
    # Two services declaring the same accessory name on the same host refer to
    # the same underlying container. This module decides whether their
    # declarations agree, by reducing each to an ordered list of normalized
    # fields and hashing it. Collections are sorted and blank values are elided,
    # so YAML key order and formatting never change the identity, while any
    # field that changes the generated Quadlet does.
    module AccessoryIdentity
      record Difference, field : String, current : String, existing : String

      # Ordered field list. The order is fixed here, never derived from Hash
      # iteration, so the fingerprint is stable across runs and processes.
      def self.fields(name : String, accessory : AccessoryConfig) : Array({String, String})
        env = accessory.env

        [
          {"image", accessory.image.to_s},
          {"host", accessory.host.to_s.strip},
          {"port", accessory.port.to_s},
          {"network", accessory.network_name.to_s},
          {"cmd", accessory.cmd.to_s},
          {"depends_on", accessory.depends_on.to_s},
          {"volumes", sorted(accessory.volumes)},
          {"secrets", sorted(accessory.secrets)},
          {"env.clear", sorted(env.try(&.clear).try(&.map { |key, value| "#{key}=#{value}" }) || EMPTY_LIST)},
          {"env.secret", sorted(env.try(&.secret) || EMPTY_LIST)},
          {"ready", readiness(name, accessory)},
        ]
      end

      # The canonical definition as an ordered map, so it can be stored in a
      # service manifest and diffed later. Crystal Hashes keep insertion order,
      # and so does the JSON round trip.
      def self.definition(name : String, accessory : AccessoryConfig) : Hash(String, String)
        fields(name, accessory).to_h
      end

      def self.canonical(name : String, accessory : AccessoryConfig) : String
        String.build do |io|
          fields(name, accessory).each do |field, value|
            io << field << '=' << value << '\n'
          end
        end
      end

      def self.fingerprint(name : String, accessory : AccessoryConfig) : String
        Digest::SHA256.hexdigest(canonical(name, accessory))
      end

      # Field-level diff between two canonical definitions of the same
      # accessory, so a conflict can say what actually differs rather than just
      # that it does. Fields absent from either side are skipped: a manifest
      # written by an older Meridian records fewer of them.
      def self.differences(current : Hash(String, String), existing : Hash(String, String)) : Array(Difference)
        current.compact_map do |field, value|
          other = existing[field]?
          next if other.nil? || other == value

          Difference.new(field: field, current: value, existing: other)
        end
      end

      # The resolved readiness contract, because it renders into the accessory's
      # `HealthCmd=`. An unresolvable one is not a conflict in itself - deploy
      # and check report that separately - so it collapses to a single marker.
      private def self.readiness(name : String, accessory : AccessoryConfig) : String
        accessory.effective_ready(name).summary
      rescue ValidationError
        "unresolved"
      end

      private def self.sorted(values : Array(String)) : String
        values.map(&.strip).reject(&.empty?).sort!.join(",")
      end

      private EMPTY_LIST = [] of String
    end
  end
end
