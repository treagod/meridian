module Meridian
  module Audit
    # Appends and reads concise, line-oriented audit entries on remote hosts.
    # Auditing is best-effort: a failed write never aborts the operation it
    # records. SSH and time dependencies are injectable for specs.
    class Logger
      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        @clock : Proc(Time) = -> { Time.utc },
        @actor : Proc(String) = -> { Audit.default_actor },
      )
      end

      # Append one audit entry to a single host's audit log.
      def record(host : String, action : String, detail : String) : Nil
        entry = Entry.new(
          timestamp: @clock.call.to_rfc3339,
          actor: @actor.call,
          action: action,
          detail: detail
        )
        append(host, entry)
      rescue SSH::CommandFailed | SSH::ConnectionError
        # Best-effort: never let an audit write break the operation it records.
      end

      # Append the same audit entry to several hosts.
      def record_all(hosts : Enumerable(String), action : String, detail : String) : Nil
        hosts.each { |host| record(host, action, detail) }
      end

      # Read the most recent audit entries from a host, newest last.
      def recent(host : String, limit : Int32) : Array(Entry)
        path = Process.quote_posix(audit_log)
        result = run_ssh(host, ["sh", "-c", "tail -n #{limit} #{path} 2>/dev/null || true"])
        return [] of Entry unless result.exit_code.zero?

        result.stdout.each_line.compact_map { |line| Entry.parse(line) }.to_a
      rescue SSH::ConnectionError
        [] of Entry
      end

      private def append(host : String, entry : Entry) : Nil
        directory = Process.quote_posix(Runtime::Paths.service_directory(@config.service))
        path = Process.quote_posix(audit_log)
        run_ssh!(
          host,
          ["sh", "-c", "mkdir -p #{directory} && cat >> #{path}"],
          "#{entry.to_line}\n"
        )
      end

      private def audit_log : String
        Runtime::Paths.audit_log(@config.service)
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

      private def run_ssh!(host : String, command : Array(String), input : String) : SSH::Result
        @ssh_executor.run!(
          host,
          command,
          input: input,
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
