require "json"

module Meridian
  module Runtime
    # Metadata describing who holds the deploy lock and why. Persisted as a
    # small JSON file inside the lock directory so a blocked caller can report
    # who/when/message when the lock is already held.
    struct LockMetadata
      include JSON::Serializable

      getter actor : String
      getter acquired_at : String
      getter message : String?

      def initialize(@actor : String, @acquired_at : String, @message : String? = nil)
      end

      # Human-readable summary used in lock-held errors and `lock status`.
      def describe : String
        summary = "held by #{actor} since #{acquired_at}"
        if (note = message) && !note.empty?
          "#{summary}: #{note}"
        else
          summary
        end
      end
    end
  end
end
