module Meridian
  module Commands
    class Accessory < Base
      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        output : IO = STDOUT,
        error : IO = STDERR,
        audit_logger : ::Meridian::Audit::Logger? = nil,
        input : IO = STDIN,
      )
        super(config, ssh_executor: ssh_executor, output: output, error: error, audit_logger: audit_logger, input: input)
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(config)
      end

      # Idempotent: any service declaring this accessory can run it and arrive
      # at the same state. Everything that could refuse is decided before the
      # first mutation, so a conflict never leaves a half-applied accessory.
      def start(name : String) : Nil
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)
        container_file = @quadlet_generator.accessory_container_file(name, accessory)

        guard_shared_definition!(host, name, accessory, container_file)
        ensure_accessory_network!(host, accessory)

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading accessory Quadlet")
        upload_ssh(host, accessory_quadlet_path(name), container_file)

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Starting #{accessory_service_unit(name)}")
        run_ssh!(host, ["systemctl", "--user", "start", accessory_service_unit(name)])
        audit_logger.record(host, "accessory", "start #{name}")
      end

      def stop(name : String, force : Bool = false) : Bool
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)
        return false unless confirm_shared_impact?(host, name, "Stopping", force)

        log(host, "Stopping #{accessory_service_unit(name)}")
        run_ssh!(host, ["systemctl", "--user", "stop", accessory_service_unit(name)])
        audit_logger.record(host, "accessory", "stop #{name}")
        true
      end

      # Removes Meridian's unit definition for the accessory. Deliberately
      # conservative about everything that outlives it: named volumes, images,
      # and the shared network are left alone, because other services may still
      # depend on them and proving otherwise is not cheap.
      def remove(name : String, force : Bool = false) : Bool
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)
        return false unless confirm_shared_impact?(host, name, "Removing", force)

        log(host, "Stopping #{accessory_service_unit(name)}")
        run_ssh!(host, ["systemctl", "--user", "stop", accessory_service_unit(name)])

        log(host, "Removing accessory Quadlet")
        run_ssh!(host, ["rm", "-f", accessory_quadlet_path(name)])

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])
        audit_logger.record(host, "accessory", "remove #{name}")
        true
      end

      def logs(name : String) : Int32
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)

        stream_ssh(host, ["journalctl", "--user", "-u", accessory_service_unit(name), "-f", "--no-pager"])
      end

      # Refuses to take over an accessory another service declares differently.
      # The manifest fingerprint is the primary comparison; the on-host unit is
      # the fallback for when manifests are missing or stale.
      private def guard_shared_definition!(
        host : String,
        name : String,
        accessory : Config::AccessoryConfig,
        container_file : String,
      ) : Nil
        others = referencing_manifests(host, name, accessory)
        return if others.empty?

        definition = Config::AccessoryIdentity.definition(name, accessory)
        fingerprint = Config::AccessoryIdentity.fingerprint(name, accessory)
        others.each do |manifest|
          ref = manifest.accessories[name]
          next if ref.fingerprint == fingerprint

          raise ArgumentError.new(conflict_message(name, definition, manifest.service, ref))
        end

        existing = remote_file(host, accessory_quadlet_path(name))
        return if existing.nil? || existing == container_file

        raise ArgumentError.new(
          "Accessory '#{name}' on #{host} is shared with #{manifest_services(others)} and its existing unit " \
          "differs from the requested definition. Meridian will not overwrite it. " \
          "Update every service that declares '#{name}' to the same definition, then run " \
          "`meridian accessory remove #{name}` and `meridian accessory start #{name}`."
        )
      end

      # The other service's canonical definition comes from its manifest on this
      # host, not from its project, so the diff never reaches across projects.
      private def conflict_message(
        name : String,
        definition : Hash(String, String),
        service : String,
        existing : Runtime::AccessoryRef,
      ) : String
        String.build do |io|
          io << "Accessory '" << name << "' conflicts with the definition already registered by service '"
          io << service << "'."

          differences = Config::AccessoryIdentity.differences(definition, existing.definition)
          unless differences.empty?
            io << "\n\nDifferent fields:"
            differences.each do |difference|
              io << "\n  " << difference.field << ":"
              io << "\n    current:  " << difference.current
              io << "\n    existing: " << difference.existing
            end
          end
        end
      end

      # A custom accessory network is a plain shared Podman network, so start
      # may create it. The app's own private service network stays owned by
      # `meridian setup`.
      private def ensure_accessory_network!(host : String, accessory : Config::AccessoryConfig) : Nil
        network = accessory.network_name
        return unless network

        # Networks Meridian generates as Quadlet units belong to `meridian
        # setup`; start only verifies the private service network is there.
        if @config.generated_network?(network)
          require_service_network!(host, "meridian accessory start") if network == service_network_name
          return
        end

        log(host, "Ensuring network #{network} exists")
        run_ssh!(host, [
          "sh", "-lc",
          "podman network exists #{Process.quote_posix(network)} || " \
          "podman network create #{Process.quote_posix(network)} >/dev/null",
        ])
      end

      # There is no owner, so stopping or removing a shared accessory affects
      # every service that declares it. Warn once, default to No, and let
      # `--force` acknowledge it. A single-service accessory says nothing.
      private def confirm_shared_impact?(host : String, name : String, verb : String, force : Bool) : Bool
        accessory = accessory_config(name)
        services = referencing_manifests(host, name, accessory).map(&.service).sort!
        return true if services.empty? || force

        @output.puts "Accessory '#{name}' is shared by #{services.size + 1} services:"
        ([@config.service] + services).sort!.each { |service| @output.puts "  #{service}" }
        @output.puts
        @output.puts "#{verb} it will affect all of them."

        return true if confirm?("Continue?")

        @output.puts "Aborted."
        false
      end

      # Other services registered on this host that name the same accessory on
      # the same host. Host mismatches are different resources, not shares.
      # Fingerprints are deliberately not filtered here: a service claiming the
      # name with a different definition still has a stake, and for lifecycle
      # warnings a false positive beats stopping a database someone else uses.
      private def referencing_manifests(
        host : String,
        name : String,
        accessory : Config::AccessoryConfig,
      ) : Array(Runtime::ServiceManifest)
        accessory_host = accessory.host.try(&.strip).presence

        other_service_manifests(host).select do |manifest|
          manifest.accessories[name]?.try(&.host) == accessory_host
        end
      end

      private def manifest_services(manifests : Array(Runtime::ServiceManifest)) : String
        manifests.map(&.service).sort!.join(", ")
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
