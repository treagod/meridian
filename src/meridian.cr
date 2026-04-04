require "option_parser"
require "./errors"
require "./commands/**"
require "./config/loader"
require "./deploy/orchestrator"
require "./health/checker"
require "./init/**"
require "./proxy/manager"
require "./quadlet/generator"
require "./ssh/executor"
require "./transfer/incremental"
require "./transfer/stream"

module Meridian
  VERSION = "0.1.0"

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

    COMMANDS = [
      "init",
      "deploy",
      "setup",
      "rollback",
      "status",
      "logs",
      "exec",
      "quadlet",
      "proxy",
    ]

    record ExecInvocation,
      host : String,
      command : Array(String),
      user : String?,
      port : Int32?,
      identity_file : String?

    record FileInvocation,
      file : String

    record QuadletInvocation,
      color : Quadlet::Color,
      output_dir : String,
      file : String

    record InitInvocation,
      force : Bool

    private class FileParseError < Exception
    end

    private class ExecParseError < Exception
    end

    private class QuadletParseError < Exception
    end

    private class InitParseError < Exception
    end

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
      return print_help(output) if args.empty?

      case args.first
      when "-h", "--help"
        print_help(output)
      when "-v", "--version"
        output.puts VERSION
        0
      else
        command = args.first
        return invalid_option(command, error) if command.starts_with?('-')

        dispatch(command, args[1..], input, output, error, ssh_executor, orchestrator_factory, proxy_manager_factory)
      end
    end

    private def self.dispatch(
      command : String,
      args : Array(String),
      input : IO,
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
      orchestrator_factory : OrchestratorFactory,
      proxy_manager_factory : ProxyManagerFactory,
    ) : Int32
      case command
      when "init"
        run_init(args, input, output, error)
      when "deploy"
        run_deploy(args, output, error, ssh_executor, orchestrator_factory)
      when "setup"
        run_setup(args, output, error, ssh_executor, proxy_manager_factory)
      when "exec"
        run_exec(args, output, error, ssh_executor)
      when "proxy"
        run_proxy(args, output, error, ssh_executor, proxy_manager_factory)
      when "quadlet"
        run_quadlet(args, output, error)
      when "rollback", "status", "logs"
        return print_stub_help(command, output) if help_requested?(args)

        output.puts "Not yet implemented"
        0
      else
        error.puts "Unknown command: #{command}"
        1
      end
    end

    private def self.run_init(
      args : Array(String),
      input : IO,
      output : IO,
      error : IO,
    ) : Int32
      return print_init_help(output) if help_requested?(args)

      invocation = parse_init_invocation(args, error)
      return 1 unless invocation

      Init::Service.new(root: Dir.current, input: input, output: output).run(force: invocation.force)
      0
    rescue ex : Init::Error | File::Error
      error.puts ex.message || "Init failed"
      1
    end

    private def self.parse_init_invocation(args : Array(String), error : IO) : InitInvocation?
      force = false

      parser = OptionParser.new
      parser.on("--force", "Overwrite existing deploy.yml and .env") { force = true }
      parser.invalid_option { |flag| raise InitParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise InitParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise InitParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      InitInvocation.new(force: force)
    rescue ex : InitParseError
      error.puts ex.message || "Invalid init arguments"
      nil
    end

    private def self.run_exec(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      return print_exec_help(output) if help_requested?(args, stop_at_separator: true)

      invocation = parse_exec_invocation(args, error)
      return 1 unless invocation

      result = ssh_executor.run(
        invocation.host,
        invocation.command,
        user: invocation.user,
        port: invocation.port,
        identity_file: invocation.identity_file
      )

      output.print result.stdout
      error.print result.stderr
      result.exit_code
    rescue ex : SSH::ConnectionError
      error.puts ex.message || "SSH connection failed"
      1
    end

    private def self.parse_exec_invocation(args : Array(String), error : IO) : ExecInvocation?
      option_args, remote_command = split_exec_args(args)
      host = nil
      user = nil
      port = nil
      identity_file = nil

      parser = OptionParser.new
      parser.on("--host HOST", "SSH host") { |value| host = value }
      parser.on("--user USER", "SSH user") { |value| user = value }
      parser.on("--port PORT", "SSH port") do |value|
        port = value.to_i? || raise ExecParseError.new("Invalid port: #{value}")
      end
      parser.on("--identity-file PATH", "SSH identity file") { |value| identity_file = value }
      parser.invalid_option { |flag| raise ExecParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ExecParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, _after_dash|
        raise ExecParseError.new("Command must follow --") unless before_dash.empty?
      end

      parser.parse(option_args.dup)

      unless parsed_host = host
        error.puts "Missing required option: --host"
        return
      end

      if remote_command.empty?
        error.puts "Missing command after --"
        return
      end

      ExecInvocation.new(
        host: parsed_host,
        command: remote_command,
        user: user,
        port: port,
        identity_file: identity_file
      )
    rescue ex : ExecParseError
      error.puts ex.message || "Invalid exec arguments"
      nil
    end

    private def self.split_exec_args(args : Array(String)) : {Array(String), Array(String)}
      separator_index = args.index("--")
      return {args, [] of String} unless separator_index

      option_args = args[0...separator_index]
      remote_command =
        if separator_index == args.size - 1
          [] of String
        else
          args[(separator_index + 1)..]
        end

      {option_args, remote_command}
    end

    private def self.invalid_option(flag : String, error : IO) : Int32
      error.puts "Invalid option: #{flag}"
      1
    end

    private def self.run_deploy(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
      orchestrator_factory : OrchestratorFactory,
    ) : Int32
      return print_deploy_help(output) if help_requested?(args)

      invocation = parse_file_invocation(args, error, "Invalid deploy arguments")
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      orchestrator = orchestrator_factory.call(config, ssh_executor, output)
      orchestrator.deploy
      0
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | Deploy::DeployFailed
      error.puts ex.message || "Deploy failed"
      1
    end

    private def self.run_setup(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
      proxy_manager_factory : ProxyManagerFactory,
    ) : Int32
      return print_setup_help(output) if help_requested?(args)

      invocation = parse_file_invocation(args, error, "Invalid setup arguments")
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      manager = proxy_manager_factory.call(config, ssh_executor, output)
      manager.setup
      0
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | Proxy::SetupFailed
      error.puts ex.message || "Proxy setup failed"
      1
    end

    private def self.parse_file_invocation(args : Array(String), error : IO, fallback : String) : FileInvocation?
      file = "deploy.yml"

      parser = OptionParser.new
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise FileParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise FileParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise FileParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      FileInvocation.new(file: file)
    rescue ex : FileParseError
      error.puts ex.message || fallback
      nil
    end

    private def self.run_proxy(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
      proxy_manager_factory : ProxyManagerFactory,
    ) : Int32
      first_arg = args.first?
      return print_proxy_help(output) if first_arg.try(&.in?(HELP_FLAGS))

      subcommand = args.first?
      unless subcommand
        error.puts "Missing proxy subcommand"
        return 1
      end

      case subcommand
      when "remove"
        return print_proxy_remove_help(output) if help_requested?(args[1..])

        invocation = parse_file_invocation(args[1..], error, "Invalid proxy remove arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        manager = proxy_manager_factory.call(config, ssh_executor, output)
        manager.remove
        0
      else
        error.puts "Unknown proxy subcommand: #{subcommand}"
        1
      end
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | Proxy::RemoveFailed
      error.puts ex.message || "Proxy command failed"
      1
    end

    private def self.run_quadlet(args : Array(String), output : IO, error : IO) : Int32
      return print_quadlet_help(output) if help_requested?(args)

      invocation = parse_quadlet_invocation(args, error)
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      generator = Quadlet::Generator.new(config)
      generator.write_to_directory(invocation.output_dir, invocation.color)
      output.puts "Wrote Quadlet preview to #{invocation.output_dir}"
      0
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError
      error.puts ex.message || "Failed to generate Quadlet preview"
      1
    end

    private def self.parse_quadlet_invocation(args : Array(String), error : IO) : QuadletInvocation?
      color = nil.as(Quadlet::Color?)
      output_dir = "./quadlet-preview"
      file = "deploy.yml"

      parser = OptionParser.new
      parser.on("--color COLOR", "Deployment color (blue or green)") do |value|
        color = Quadlet::Color.parse?(value) || raise QuadletParseError.new("Invalid color: #{value}")
      end
      parser.on("--output-dir DIR", "Directory for generated Quadlet files") { |value| output_dir = value }
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise QuadletParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise QuadletParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise QuadletParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      unless parsed_color = color
        error.puts "Missing required option: --color"
        return
      end

      QuadletInvocation.new(color: parsed_color, output_dir: output_dir, file: file)
    rescue ex : QuadletParseError | ArgumentError
      error.puts ex.message || "Invalid quadlet arguments"
      nil
    end

    private def self.help_requested?(args : Array(String), stop_at_separator : Bool = false) : Bool
      help_args =
        if stop_at_separator
          option_args, _remote_command = split_exec_args(args)
          option_args
        else
          args
        end

      help_args.any?(&.in?(HELP_FLAGS))
    end

    private def self.print_help(io : IO) : Int32
      io.puts "Usage: meridian [command] [options]"
      io.puts
      io.puts "Commands:"
      COMMANDS.each do |command|
        io.puts "    #{command}"
      end
      io.puts
      io.puts "Options:"
      io.puts "    -h, --help                 Show this help"
      io.puts "    -v, --version              Show the version"
      io.puts
      io.puts "Run `meridian COMMAND --help` for command-specific options."
      0
    end

    private def self.print_init_help(io : IO) : Int32
      io.puts "Usage: meridian init [options]"
      io.puts
      io.puts "Generate deploy.yml and .env for the current project directory."
      io.puts
      io.puts "Options:"
      io.puts "    --force                    Overwrite existing deploy.yml and .env"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_deploy_help(io : IO) : Int32
      io.puts "Usage: meridian deploy [options]"
      io.puts
      io.puts "Deploy the configured application."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_setup_help(io : IO) : Int32
      io.puts "Usage: meridian setup [options]"
      io.puts
      io.puts "Install and start kamal-proxy on web hosts."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_exec_help(io : IO) : Int32
      io.puts "Usage: meridian exec [options] -- COMMAND [ARGS...]"
      io.puts
      io.puts "Run an arbitrary command on a remote host over SSH."
      io.puts
      io.puts "Options:"
      io.puts "    --host HOST                SSH host"
      io.puts "    --user USER                SSH user"
      io.puts "    --port PORT                SSH port"
      io.puts "    --identity-file PATH       SSH identity file"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_quadlet_help(io : IO) : Int32
      io.puts "Usage: meridian quadlet [options]"
      io.puts
      io.puts "Generate Quadlet files locally for inspection."
      io.puts
      io.puts "Options:"
      io.puts "    --color COLOR              Deployment color (blue or green)"
      io.puts "    --output-dir DIR           Directory for generated Quadlet files"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_proxy_help(io : IO) : Int32
      io.puts "Usage: meridian proxy SUBCOMMAND [options]"
      io.puts
      io.puts "Proxy subcommands:"
      io.puts "    remove                     Stop and remove kamal-proxy"
      io.puts
      io.puts "Run `meridian proxy remove --help` for subcommand options."
      0
    end

    private def self.print_proxy_remove_help(io : IO) : Int32
      io.puts "Usage: meridian proxy remove [options]"
      io.puts
      io.puts "Stop and remove kamal-proxy from web hosts."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_stub_help(command : String, io : IO) : Int32
      io.puts "Usage: meridian #{command}"
      io.puts
      io.puts "#{command.capitalize} is not implemented yet."
      io.puts
      io.puts "Options:"
      io.puts "    -h, --help                 Show this help"
      0
    end
  end
end
