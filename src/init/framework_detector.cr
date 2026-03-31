module Meridian
  module Init
    record DetectedFramework,
      name : String,
      clear_env : Hash(String, String),
      healthcheck_path : String?,
      note : String? = nil

    class FrameworkDetector
      def initialize(@root : String)
      end

      def detect : DetectedFramework?
        MartenDetector.new(@root).detect ||
          RailsDetector.new(@root).detect ||
          ElixirDetector.new(@root).detect ||
          GoDetector.new(@root).detect ||
          NodeDetector.new(@root).detect
      end
    end

    abstract class Detector
      def initialize(@root : String)
      end

      abstract def detect : DetectedFramework?

      protected def root_path(relative_path : String) : String
        File.join(@root, relative_path)
      end

      protected def root_file?(relative_path : String) : Bool
        File.file?(root_path(relative_path))
      end

      protected def root_dir?(relative_path : String) : Bool
        Dir.exists?(root_path(relative_path))
      end

      protected def read_root_file(relative_path : String) : String?
        return unless root_file?(relative_path)

        File.read(root_path(relative_path))
      rescue ex : File::Error
        nil
      end
    end

    class MartenDetector < Detector
      HEALTH_ROUTE_PATTERN = /["']\/health["']/

      def detect : DetectedFramework?
        required_paths = [
          "manage.cr",
          "src/project.cr",
          "src/server.cr",
          "config/routes.cr",
          "config/settings/base.cr",
        ]
        return unless required_paths.all? { |path| root_file?(path) }

        manage_content = read_root_file("manage.cr")
        project_content = read_root_file("src/project.cr")
        server_content = read_root_file("src/server.cr")
        routes_content = read_root_file("config/routes.cr")
        return unless manage_content && project_content && server_content && routes_content

        return unless manage_content.includes?("Marten.setup")
        return unless manage_content.includes?("Marten::CLI.run")
        return unless project_content.includes?(%q(require "marten"))
        return unless server_content.includes?("Marten.start")

        note = nil.as(String?)
        healthcheck_path = nil.as(String?)

        if HEALTH_ROUTE_PATTERN.matches?(routes_content)
          healthcheck_path = "/health"
        else
          note = "Detected Marten app but no explicit /health route was found; using the default /health."
        end

        DetectedFramework.new(
          name: "Marten",
          clear_env: {"MARTEN_ENV" => "production"},
          healthcheck_path: healthcheck_path,
          note: note
        )
      end
    end

    class RailsDetector < Detector
      UP_ROUTE_PATTERN = /["']\/up["']/

      def detect : DetectedFramework?
        return unless root_file?("Gemfile")
        return unless root_file?("config.ru") || root_file?("bin/rails")

        note = nil.as(String?)
        healthcheck_path = nil.as(String?)
        up_sources = [read_root_file("config.ru"), read_root_file("config/routes.rb")].compact

        if up_sources.any? { |source| UP_ROUTE_PATTERN.matches?(source) }
          healthcheck_path = "/up"
        else
          note = "Detected Rails app but no explicit /up route was found; using the default /health."
        end

        DetectedFramework.new(
          name: "Rails",
          clear_env: {"RAILS_ENV" => "production"},
          healthcheck_path: healthcheck_path,
          note: note
        )
      end
    end

    class ElixirDetector < Detector
      def detect : DetectedFramework?
        return unless root_file?("mix.exs")

        DetectedFramework.new(
          name: "Elixir",
          clear_env: {"MIX_ENV" => "prod"},
          healthcheck_path: nil
        )
      end
    end

    class GoDetector < Detector
      def detect : DetectedFramework?
        return unless root_file?("go.mod")

        DetectedFramework.new(
          name: "Go",
          clear_env: {} of String => String,
          healthcheck_path: nil
        )
      end
    end

    class NodeDetector < Detector
      def detect : DetectedFramework?
        return unless root_file?("package.json")

        DetectedFramework.new(
          name: "Node",
          clear_env: {"NODE_ENV" => "production"},
          healthcheck_path: nil
        )
      end
    end
  end
end
