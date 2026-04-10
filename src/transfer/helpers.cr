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
    end
  end
end
