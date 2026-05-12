require "option_parser"
require "./errors"
require "./commands/base"
require "./commands/**"
require "./config/loader"
require "./deploy/plan"
require "./deploy/orchestrator"
require "./health/checker"
require "./init/**"
require "./proxy/manager"
require "./quadlet/generator"
require "./server/bootstrapper"
require "./ssh/executor"
require "./transfer/incremental"
require "./transfer/stream"
require "./cli/server_bootstrap_invocation"
require "./cli/context"
require "./cli/command"
require "./cli/group_command"
require "./cli/registry"
require "./cli/commands/**"

module Meridian
  VERSION = {{ `shards version`.strip.stringify }}

  module CLI
    HELP_FLAGS = ["-h", "--help"]

    alias OrchestratorFactory = Proc(Config::DeployConfig, SSH::Executor, IO, Deploy::Orchestrator)
    alias ProxyManagerFactory = Proc(Config::DeployConfig, SSH::Executor, IO, Proxy::Manager)

    DEFAULT_ORCHESTRATOR_FACTORY = ->(config : Config::DeployConfig, ssh_executor : SSH::Executor, output : IO) do
      Deploy::Orchestrator.new(config, ssh_executor: ssh_executor, output: output)
    end

    DEFAULT_PROXY_MANAGER_FACTORY = ->(config : Config::DeployConfig, ssh_executor : SSH::Executor, output : IO) do
      Proxy::Manager.new(config, ssh_executor: ssh_executor, output: output)
    end

    REGISTRY = Registry.new([
      Commands::Init,
      Commands::Deploy,
      Commands::Setup,
      Commands::Rollback,
      Commands::Status,
      Commands::Check,
      Commands::Plan,
      Commands::Logs,
      Commands::Exec,
      Commands::Run,
      Commands::Accessory,
      Commands::AccessoryStart,
      Commands::AccessoryStop,
      Commands::AccessoryLogs,
      Commands::Secret,
      Commands::SecretSet,
      Commands::SecretRm,
      Commands::SecretLs,
      Commands::Quadlet,
      Commands::Proxy,
      Commands::ProxyRemove,
      Commands::Server,
      Commands::ServerBootstrap,
    ] of Command.class)

    def self.run(
      args : Array(String),
      *,
      input : IO = STDIN,
      output : IO = STDOUT,
      error : IO = STDERR,
      ssh_executor : SSH::Executor = SSH::Executor.new,
      orchestrator_factory : OrchestratorFactory = DEFAULT_ORCHESTRATOR_FACTORY,
      proxy_manager_factory : ProxyManagerFactory = DEFAULT_PROXY_MANAGER_FACTORY,
    ) : Int32
      return print_top_help(output) if args.empty?

      first = args.first
      case first
      when "-h", "--help"
        return print_top_help(output)
      when "-v", "--version"
        output.puts VERSION
        return 0
      end

      if first.starts_with?('-')
        error.puts "Invalid option: #{first}"
        return 1
      end

      ctx = Context.new(input, output, error, ssh_executor, orchestrator_factory, proxy_manager_factory)

      if match = REGISTRY.resolve(args)
        klass, remaining = match
        klass.new.invoke(ctx, remaining)
      else
        error.puts "Unknown command: #{first}"
        1
      end
    end

    private def self.print_top_help(io : IO) : Int32
      io.puts "Usage: meridian [command] [options]"
      io.puts
      io.puts "Commands:"
      REGISTRY.top_level.each do |klass|
        io.puts "    #{klass.new.name}"
      end
      io.puts
      io.puts "Options:"
      io.puts "    -h, --help                 Show this help"
      io.puts "    -v, --version              Show the version"
      io.puts
      io.puts "Run `meridian COMMAND --help` for command-specific options."
      0
    end
  end
end
