module Meridian
  module CLI
    module Commands
      class Lock < GroupCommand
        def name : String
          "lock"
        end

        def summary : String
          "Inspect and manage the deploy lock"
        end

        def usage : String
          "Usage: meridian lock SUBCOMMAND [options]"
        end

        def subcommand_summaries : Array({String, String})
          [
            {"status", "Show whether a deploy lock is held"},
            {"acquire", "Acquire the deploy lock"},
            {"release", "Release the deploy lock"},
          ]
        end

        def failure_message : String
          "Lock command failed"
        end
      end

      abstract class LockAction < Command
        @file = "deploy.yml"

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
        end

        def rescuable : Array(Exception.class)
          super + [
            ::Meridian::Lock::LockHeld,
            ::Meridian::Lock::LockError,
            SSH::CommandFailed,
            SSH::ConnectionError,
          ] of Exception.class
        end

        def failure_message : String
          "Lock command failed"
        end

        protected def build_lock_manager(ctx : Context) : ::Meridian::Lock::Manager
          config = Config::Loader.load(@file)
          ::Meridian::Lock::Manager.new(config, ssh_executor: ctx.ssh_executor, output: ctx.output)
        end
      end

      class LockStatus < LockAction
        def name : String
          "lock status"
        end

        def summary : String
          "Show whether a deploy lock is held"
        end

        def usage : String
          "Usage: meridian lock status [options]"
        end

        def description : String
          "Report whether a deploy lock is held on the lock host."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          status = build_lock_manager(ctx).status
          if status.held
            if metadata = status.metadata
              ctx.output.puts "Deploy lock on #{status.host} is #{metadata.describe}"
            else
              ctx.output.puts "Deploy lock on #{status.host} is held (no metadata available)"
            end
          else
            ctx.output.puts "No deploy lock held on #{status.host}"
          end
          0
        end
      end

      class LockAcquire < LockAction
        @message : String? = nil

        def name : String
          "lock acquire"
        end

        def summary : String
          "Acquire the deploy lock"
        end

        def usage : String
          "Usage: meridian lock acquire [options]"
        end

        def description : String
          "Acquire the deploy lock so concurrent deploys are blocked until release."
        end

        def configure(parser : OptionParser) : Nil
          super
          parser.on("--message MESSAGE", "Reason recorded with the lock") { |v| @message = v }
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          manager = build_lock_manager(ctx)
          metadata = manager.acquire(@message)
          ctx.output.puts "Acquired deploy lock on #{manager.lock_host} (#{metadata.describe})"
          0
        end
      end

      class LockRelease < LockAction
        def name : String
          "lock release"
        end

        def summary : String
          "Release the deploy lock"
        end

        def usage : String
          "Usage: meridian lock release [options]"
        end

        def description : String
          "Release the deploy lock, announcing who held it."
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          build_lock_manager(ctx).release(announce: true)
          0
        end
      end
    end
  end
end
