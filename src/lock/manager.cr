module Meridian
  module Lock
    # A simple remote deploy lock. Acquisition is atomic because it relies on
    # `mkdir` of the lock directory, which fails on any host filesystem when
    # the directory already exists. Lock metadata is stored as a small JSON
    # file inside that directory. SSH, time, and actor dependencies are
    # injectable for specs.
    class Manager
      record Status, host : String, held : Bool, metadata : Runtime::LockMetadata?

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        @output : IO = STDOUT,
        @clock : Proc(Time) = -> { Time.utc },
        @actor : Proc(String) = -> { Audit.default_actor },
        audit_logger : Audit::Logger? = nil,
      )
        @audit_logger = audit_logger || Audit::Logger.new(@config, @ssh_executor)
      end

      # The host that owns the deploy lock - the first web host when present,
      # otherwise the first configured host of any role.
      def lock_host : String
        if web = @config.servers["web"]?
          if host = web.hosts.first?
            return host
          end
        end

        @config.servers.each_value do |server|
          if host = server.hosts.first?
            return host
          end
        end

        raise LockError.new("Deploy lock requires at least one configured host")
      end

      def status : Status
        host = lock_host
        if directory_exists?(host, lock_directory)
          Status.new(host: host, held: true, metadata: read_metadata(host))
        else
          Status.new(host: host, held: false, metadata: nil)
        end
      rescue ex : SSH::ConnectionError
        raise LockError.new(ex.message || "Failed to reach lock host")
      end

      # Atomically claim the deploy lock. Raises LockHeld if another caller
      # already holds it.
      def acquire(message : String? = nil) : Runtime::LockMetadata
        host = lock_host
        run_ssh!(host, ["mkdir", "-p", service_directory])

        created = run_ssh(host, ["mkdir", lock_directory])
        unless created.exit_code.zero?
          raise held_error(host) if directory_exists?(host, lock_directory)

          raise LockError.new(
            "Failed to acquire deploy lock on #{host}: " \
            "#{created.stderr.strip.presence || "mkdir exited #{created.exit_code}"}"
          )
        end

        establish_lock(host, message)
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise LockError.new(ex.message || "Failed to acquire deploy lock")
      end

      # Fill in the lock directory we just created. It is already ours, so every
      # failure from here on has to hand it back - otherwise the next deploy
      # inherits a lock nobody holds that only `meridian lock release` can clear.
      # The rescue is deliberately unfiltered: an unexpected error is exactly the
      # case that used to strand the lock. It re-raises rather than handling, so
      # the caller above still does the `LockError` conversion.
      private def establish_lock(host : String, message : String?) : Runtime::LockMetadata
        metadata = Runtime::LockMetadata.new(
          actor: @actor.call,
          acquired_at: @clock.call.to_rfc3339,
          message: message.try(&.strip).presence
        )
        upload(host, metadata_file, "#{metadata.to_json}\n")
        @audit_logger.record(host, "lock", acquire_detail(metadata))
        metadata
      rescue ex
        discard_partial_lock(host)
        raise ex
      end

      # Release the deploy lock. A stale lock is only ever cleared by an
      # explicit release - never silently - and the released lock is announced.
      def release(*, announce : Bool = true) : Runtime::LockMetadata?
        host = lock_host
        unless directory_exists?(host, lock_directory)
          @output.puts "No deploy lock held on #{host}" if announce
          return
        end

        metadata = read_metadata(host)
        if announce
          @output.puts "Releasing deploy lock on #{host} " \
                       "(#{metadata.try(&.describe) || "no metadata available"})"
        end
        run_ssh!(host, ["rm", "-rf", lock_directory])
        @audit_logger.record(host, "lock", "released")
        metadata
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise LockError.new(ex.message || "Failed to release deploy lock")
      end

      private def acquire_detail(metadata : Runtime::LockMetadata) : String
        if note = metadata.message
          "acquired: #{note}"
        else
          "acquired"
        end
      end

      private def held_error(host : String) : LockHeld
        metadata = read_metadata(host)
        if metadata
          LockHeld.new("Deploy lock on #{host} is #{metadata.describe}")
        else
          LockHeld.new("Deploy lock on #{host} is held (no metadata available)")
        end
      end

      private def read_metadata(host : String) : Runtime::LockMetadata?
        result = run_ssh(host, ["cat", metadata_file])
        return unless result.exit_code.zero?

        text = result.stdout.strip
        return if text.empty?

        Runtime::LockMetadata.from_json(text)
      rescue JSON::ParseException
        nil
      end

      # Best-effort cleanup of a lock directory we created but never finished
      # taking. Deliberately not `release`: there is no metadata to announce and
      # nothing to audit as released. A failure here is not worth masking the
      # original error that got us here.
      private def discard_partial_lock(host : String) : Nil
        run_ssh(host, ["rm", "-rf", lock_directory])
      rescue SSH::CommandFailed | SSH::ConnectionError
      end

      private def directory_exists?(host : String, path : String) : Bool
        run_ssh(host, ["test", "-d", path]).exit_code.zero?
      end

      private def service_directory : String
        Runtime::Paths.service_directory(@config.service)
      end

      private def lock_directory : String
        Runtime::Paths.lock_file(@config.service)
      end

      private def metadata_file : String
        Runtime::Paths.lock_metadata_file(@config.service)
      end

      private def run_ssh(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def run_ssh!(host : String, command : Array(String)) : SSH::Result
        @ssh_executor.run!(
          host,
          command,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def upload(host : String, remote_path : String, content : String) : Nil
        @ssh_executor.upload(
          host,
          remote_path,
          content,
          user: ssh_user,
          port: ssh_port,
          identity_file: ssh_identity_file,
          proxy_jump: ssh_proxy_jump,
          connect_timeout: ssh_connect_timeout,
          keepalive: ssh_keepalive,
          keepalive_interval: ssh_keepalive_interval
        )
      end

      private def ssh_user : String
        @config.ssh.user
      end

      private def ssh_port : Int32?
        port = @config.ssh.port
        port == 22 ? nil : port
      end

      private def ssh_identity_file : String?
        @config.ssh.identity_file
      end

      private def ssh_proxy_jump : String?
        @config.ssh.proxy_jump
      end

      private def ssh_connect_timeout : Int32
        @config.ssh.connect_timeout
      end

      private def ssh_keepalive : Bool
        @config.ssh.keepalive?
      end

      private def ssh_keepalive_interval : Int32
        @config.ssh.keepalive_interval
      end
    end
  end
end
