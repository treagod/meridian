module Meridian
  module Commands
    class Prune < Base
      ALLOWED_ROOTS = {File.join(".config", "containers"), Runtime::Paths::ROOT}

      record Stale, path : String, unit : String?, volume : String?

      def run(force : Bool = false) : Bool
        expected = Runtime::ServiceManifest.from_config(config).generated_files
        pruned = false

        all_hosts.each do |host|
          stale, rejected = drift_on(host, expected)

          rejected.each do |path|
            log(host, "Refusing to remove #{path}: outside #{ALLOWED_ROOTS.join(" and ")}")
          end

          if stale.empty?
            log(host, "Nothing to prune")
            next
          end

          announce(host, stale)
          unless force || confirm?("Remove them?")
            output.puts "Aborted."
            return pruned
          end

          remove(host, stale)
          pruned = true
        end

        pruned
      end

      private def drift_on(host : String, expected : Array(String)) : {Array(Stale), Array(String)}
        text = remote_file(host, manifest_file)
        return {[] of Stale, [] of String} unless text

        recorded = Runtime::ServiceManifest.from_json(text).generated_files
        stale, rejected = (recorded - expected).partition { |path| allowed?(path) }
        {stale.map { |path| classify(path) }, rejected}
      rescue ex : JSON::ParseException
        raise ArgumentError.new("Invalid Meridian service manifest on #{host}: #{ex.message}")
      end

      private def allowed?(path : String) : Bool
        return false if path.starts_with?('/') || path.split('/').includes?("..")

        ALLOWED_ROOTS.any? { |root| path.starts_with?("#{root}/") }
      end

      private def classify(path : String) : Stale
        name = File.basename(path)
        return Stale.new(path, nil, nil) unless File.dirname(path) == Quadlet::DIRECTORY

        case
        when name.ends_with?(".container")
          Stale.new(path, "#{name.rchop(".container")}.service", nil)
        when name.ends_with?(".network")
          Stale.new(path, Runtime::ServiceNetwork.unit(name.rchop(".network")), nil)
        when name.ends_with?(".volume")
          base = name.rchop(".volume")
          Stale.new(path, "#{base}-volume.service", "systemd-#{base}")
        else
          Stale.new(path, nil, nil)
        end
      end

      private def announce(host : String, stale : Array(Stale)) : Nil
        output.puts "[#{host}] Stale generated files: #{stale.size}"
        stale.each do |entry|
          unit = entry.unit
          output.puts unit ? "  #{entry.path} (stops #{unit})" : "  #{entry.path}"
        end

        volumes = stale.compact_map(&.volume)
        return if volumes.empty?

        output.puts
        output.puts "Podman volumes are not removed:"
        volumes.each { |volume| output.puts "  #{volume}" }
      end

      private def remove(host : String, stale : Array(Stale)) : Nil
        stale.each do |entry|
          if unit = entry.unit
            log(host, "Stopping #{unit}")
            # A missing unit must not abort the remaining cleanup.
            run_ssh(host, ["systemctl", "--user", "stop", unit])
          end

          log(host, "Removing #{entry.path}")
          run_ssh!(host, ["rm", "-f", entry.path])
        end

        if stale.any?(&.unit)
          log(host, "Reloading user systemd")
          run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        end

        audit_logger.record(host, "prune", "removed generated files: #{stale.size}")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
