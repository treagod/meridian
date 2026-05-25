module Meridian
  module Audit
    # Field separator for line-oriented audit entries. Chosen so entries stay
    # readable when inspected with a plain `tail` or `cat` over SSH.
    SEPARATOR = " | "

    # Best-effort identity of whoever invoked Meridian, recorded in audit
    # entries and lock metadata.
    def self.default_actor : String
      user = ENV["USER"]?.presence || ENV["LOGNAME"]?.presence || "unknown"
      host =
        begin
          System.hostname
        rescue
          "unknown"
        end
      "#{user}@#{host}"
    end

    # A single audit log line: when, who, which action, and a concise detail.
    record Entry,
      timestamp : String,
      actor : String,
      action : String,
      detail : String do
      def to_line : String
        {timestamp, actor, action, collapse(detail)}.join(SEPARATOR)
      end

      def self.parse(line : String) : Entry?
        text = line.strip
        return if text.empty?

        parts = text.split(SEPARATOR, 4)
        return unless parts.size == 4

        Entry.new(
          timestamp: parts[0],
          actor: parts[1],
          action: parts[2],
          detail: parts[3]
        )
      end

      private def collapse(value : String) : String
        value.gsub(/\s+/, " ").strip
      end
    end
  end
end
