module Meridian
  module Transfer
    private module Helpers
      private def format_duration(duration : Time::Span) : String
        if duration < 1.second
          "#{duration.total_milliseconds.round(1)}ms"
        else
          "#{duration.total_seconds.round(2)}s"
        end
      end

      private def format_bytes(bytes : Int64) : String
        return "#{bytes} B" if bytes < 1024

        size = bytes.to_f
        {"KB", "MB", "GB", "TB", "PB"}.each do |unit|
          size /= 1024.0
          return "%.1f %s" % {size, unit} if size < 1024.0
        end

        "%.1f PB" % size
      end
    end
  end
end
