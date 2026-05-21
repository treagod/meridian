require "json"

module Meridian
  module Runtime
    struct ReleaseRecord
      include JSON::Serializable

      getter service : String
      getter role : String
      getter host : String
      getter color : String
      getter image : String
      getter release_id : String
      getter deployed_at : String

      def initialize(
        @service : String,
        @role : String,
        @host : String,
        @color : String,
        @image : String,
        @release_id : String,
        @deployed_at : String,
      )
      end
    end

    struct ReleaseState
      include JSON::Serializable

      SCHEMA_VERSION = 1

      getter schema_version : Int32
      getter current : ReleaseRecord
      getter previous : ReleaseRecord?

      def initialize(@current : ReleaseRecord, @previous : ReleaseRecord? = nil)
        @schema_version = SCHEMA_VERSION
      end

      def self.promote(existing : ReleaseState?, new_current : ReleaseRecord) : ReleaseState
        previous = existing.try(&.current)
        ReleaseState.new(current: new_current, previous: previous)
      end

      def swap : ReleaseState
        prior = previous || raise ArgumentError.new("Cannot swap release state without a previous release")
        ReleaseState.new(current: prior, previous: current)
      end
    end
  end
end
