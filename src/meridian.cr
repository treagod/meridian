require "option_parser"
require "./errors"
require "./commands/base"
require "./commands/**"
require "./config/loader"
require "./deploy/orchestrator"
require "./health/checker"
require "./init/**"
require "./proxy/manager"
require "./quadlet/generator"
require "./server/bootstrapper"
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
      "run",
      "accessory",
      "secret",
      "quadlet",
      "proxy",
      "server",
    ]

    record ExecInvocation,
      role : String,
      command : Array(String),
      host : String?,
      file : String

    record RunInvocation,
      role : String,
      command : Array(String),
      host : String?,
      file : String

    record LogsInvocation,
      host : String?,
      file : String

    record AccessoryInvocation,
      name : String,
      file : String

    record SecretSetInvocation,
      name : String,
      value : String?,
      role : String,
      file : String

    record SecretNameInvocation,
      name : String,
      role : String,
      file : String

    record SecretRoleInvocation,
      role : String,
      file : String

    record FileInvocation,
      file : String

    record QuadletInvocation,
      color : Quadlet::Color,
      output_dir : String,
      file : String

    record InitInvocation,
      force : Bool

    record ServerBootstrapInvocation,
      host : String?,
      port : Int32?,
      root_user : String,
      deploy_user : String?,
      accept_new_host_key : Bool,
      enable_auto_updates : Bool,
      passwordless_sudo : Bool,
      rootless_low_ports : Bool,
      rootless_port_start : Int32,
      file : String

    private class ParseError < Exception
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
      when "run"
        run_run(args, output, error, ssh_executor)
      when "accessory"
        run_accessory(args, output, error, ssh_executor)
      when "secret"
        run_secret(args, input, output, error, ssh_executor)
      when "proxy"
        run_proxy(args, output, error, ssh_executor, proxy_manager_factory)
      when "quadlet"
        run_quadlet(args, output, error)
      when "rollback"
        run_rollback(args, output, error, ssh_executor)
      when "status"
        run_status(args, output, error, ssh_executor)
      when "logs"
        run_logs(args, output, error, ssh_executor)
      when "server"
        run_server(args, output, error, ssh_executor)
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
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      InitInvocation.new(force: force)
    rescue ex : ParseError
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

      config = Config::Loader.load(invocation.file)
      Commands::Exec.new(config, ssh_executor: ssh_executor, output: output, error: error).run(
        invocation.role,
        invocation.command,
        invocation.host
      )
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError | SSH::ConnectionError
      error.puts ex.message || "Exec failed"
      1
    end

    private def self.parse_exec_invocation(args : Array(String), error : IO) : ExecInvocation?
      option_args, remote_command = split_exec_args(args)
      role = option_args.first?
      host = nil
      file = "deploy.yml"

      if role.try(&.starts_with?('-'))
        role = nil
      end

      parser_args =
        if role
          option_args.size > 1 ? option_args[1..] : [] of String
        else
          option_args
        end

      parser = OptionParser.new
      parser.on("--host HOST", "SSH host") { |value| host = value }
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, _after_dash|
        raise ParseError.new("Unknown arguments: #{before_dash.join(" ")}") unless before_dash.empty?
      end

      parser.parse(parser_args.dup)

      unless parsed_role = role
        error.puts "Missing required role"
        return
      end

      if remote_command.empty?
        error.puts "Missing command after --"
        return
      end

      ExecInvocation.new(
        role: parsed_role,
        command: remote_command,
        host: host,
        file: file
      )
    rescue ex : ParseError
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

    private def self.run_run(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      return print_run_help(output) if help_requested?(args, stop_at_separator: true)

      invocation = parse_run_invocation(args, error)
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      Commands::Run.new(config, ssh_executor: ssh_executor, output: output, error: error).run(
        invocation.role,
        invocation.command,
        invocation.host
      )
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError | SSH::ConnectionError
      error.puts ex.message || "Run failed"
      1
    end

    private def self.parse_run_invocation(args : Array(String), error : IO) : RunInvocation?
      option_args, remote_command = split_exec_args(args)
      role = option_args.first?
      host = nil
      file = "deploy.yml"

      if role.try(&.starts_with?('-'))
        role = nil
      end

      parser_args =
        if role
          option_args.size > 1 ? option_args[1..] : [] of String
        else
          option_args
        end

      parser = OptionParser.new
      parser.on("--host HOST", "SSH host") { |value| host = value }
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, _after_dash|
        raise ParseError.new("Unknown arguments: #{before_dash.join(" ")}") unless before_dash.empty?
      end

      parser.parse(parser_args.dup)

      unless parsed_role = role
        error.puts "Missing required role"
        return
      end

      if remote_command.empty?
        error.puts "Missing command after --"
        return
      end

      RunInvocation.new(
        role: parsed_role,
        command: remote_command,
        host: host,
        file: file
      )
    rescue ex : ParseError
      error.puts ex.message || "Invalid run arguments"
      nil
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
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      FileInvocation.new(file: file)
    rescue ex : ParseError
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
      subcommand = args.first?
      return print_proxy_help(output) if subcommand.try(&.in?(HELP_FLAGS))

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

    private def self.run_accessory(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      subcommand = args.first?
      return print_accessory_help(output) if subcommand.try(&.in?(HELP_FLAGS))

      unless subcommand
        error.puts "Missing accessory subcommand"
        return 1
      end

      case subcommand
      when "start"
        return print_accessory_start_help(output) if help_requested?(args[1..])

        invocation = parse_accessory_invocation(args[1..], error, "Invalid accessory start arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Accessory.new(config, ssh_executor: ssh_executor, output: output, error: error).start(invocation.name)
        0
      when "stop"
        return print_accessory_stop_help(output) if help_requested?(args[1..])

        invocation = parse_accessory_invocation(args[1..], error, "Invalid accessory stop arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Accessory.new(config, ssh_executor: ssh_executor, output: output, error: error).stop(invocation.name)
        0
      when "logs"
        return print_accessory_logs_help(output) if help_requested?(args[1..])

        invocation = parse_accessory_invocation(args[1..], error, "Invalid accessory logs arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Accessory.new(config, ssh_executor: ssh_executor, output: output, error: error).logs(invocation.name)
      else
        error.puts "Unknown accessory subcommand: #{subcommand}"
        1
      end
    rescue ex : Config::ValidationError | Config::UnknownAccessory | YAML::ParseException | File::NotFoundError | ArgumentError | SSH::CommandFailed | SSH::ConnectionError
      error.puts ex.message || "Accessory command failed"
      1
    end

    private def self.parse_accessory_invocation(
      args : Array(String),
      error : IO,
      fallback : String,
    ) : AccessoryInvocation?
      name = args.first?
      file = "deploy.yml"

      if name.try(&.starts_with?('-'))
        name = nil
      end

      parser_args =
        if name
          args.size > 1 ? args[1..] : [] of String
        else
          args
        end

      parser = OptionParser.new
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(parser_args.dup)

      unless parsed_name = name
        error.puts "Missing accessory name"
        return
      end

      AccessoryInvocation.new(name: parsed_name, file: file)
    rescue ex : ParseError
      error.puts ex.message || fallback
      nil
    end

    private def self.run_secret(
      args : Array(String),
      input : IO,
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      subcommand = args.first?
      return print_secret_help(output) if subcommand.try(&.in?(HELP_FLAGS))

      unless subcommand
        error.puts "Missing secret subcommand"
        return 1
      end

      case subcommand
      when "set"
        return print_secret_set_help(output) if help_requested?(args[1..])

        invocation = parse_secret_set_invocation(args[1..], error)
        return 1 unless invocation

        value = invocation.value || input.gets_to_end.chomp
        config = Config::Loader.load(invocation.file)
        Commands::Secret.new(config, ssh_executor: ssh_executor, output: output, error: error).set(invocation.name, value, invocation.role)
        0
      when "rm"
        return print_secret_rm_help(output) if help_requested?(args[1..])

        invocation = parse_secret_name_invocation(args[1..], error, "Invalid secret rm arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Secret.new(config, ssh_executor: ssh_executor, output: output, error: error).rm(invocation.name, invocation.role)
        0
      when "ls"
        return print_secret_ls_help(output) if help_requested?(args[1..])

        invocation = parse_secret_role_invocation(args[1..], error, "Invalid secret ls arguments")
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Secret.new(config, ssh_executor: ssh_executor, output: output, error: error).ls(invocation.role)
        0
      else
        error.puts "Unknown secret subcommand: #{subcommand}"
        1
      end
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError | SSH::CommandFailed | SSH::ConnectionError
      error.puts ex.message || "Secret command failed"
      1
    end

    private def self.parse_secret_set_invocation(args : Array(String), error : IO) : SecretSetInvocation?
      name = args.first?
      value = nil.as(String?)
      role = "web"
      file = "deploy.yml"

      if name.try(&.starts_with?('-'))
        name = nil
      end

      parser_args =
        if name
          args.size > 1 ? args[1..] : [] of String
        else
          args
        end

      parser = OptionParser.new
      parser.on("--value VALUE", "Secret value (default: read from stdin)") { |v| value = v }
      parser.on("--role ROLE", "Target role (default: web)") { |v| role = v }
      parser.on("--file PATH", "Path to deploy config") { |v| file = v }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(parser_args.dup)

      unless parsed_name = name
        error.puts "Missing secret name"
        return
      end

      SecretSetInvocation.new(name: parsed_name, value: value, role: role, file: file)
    rescue ex : ParseError
      error.puts ex.message || "Invalid secret set arguments"
      nil
    end

    private def self.parse_secret_name_invocation(
      args : Array(String),
      error : IO,
      fallback : String,
    ) : SecretNameInvocation?
      name = args.first?
      role = "web"
      file = "deploy.yml"

      if name.try(&.starts_with?('-'))
        name = nil
      end

      parser_args =
        if name
          args.size > 1 ? args[1..] : [] of String
        else
          args
        end

      parser = OptionParser.new
      parser.on("--role ROLE", "Target role (default: web)") { |v| role = v }
      parser.on("--file PATH", "Path to deploy config") { |v| file = v }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(parser_args.dup)

      unless parsed_name = name
        error.puts "Missing secret name"
        return
      end

      SecretNameInvocation.new(name: parsed_name, role: role, file: file)
    rescue ex : ParseError
      error.puts ex.message || fallback
      nil
    end

    private def self.parse_secret_role_invocation(
      args : Array(String),
      error : IO,
      fallback : String,
    ) : SecretRoleInvocation?
      role = "web"
      file = "deploy.yml"

      parser = OptionParser.new
      parser.on("--role ROLE", "Target role (default: web)") { |v| role = v }
      parser.on("--file PATH", "Path to deploy config") { |v| file = v }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      SecretRoleInvocation.new(role: role, file: file)
    rescue ex : ParseError
      error.puts ex.message || fallback
      nil
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
        color = Quadlet::Color.parse?(value) || raise ParseError.new("Invalid color: #{value}")
      end
      parser.on("--output-dir DIR", "Directory for generated Quadlet files") { |value| output_dir = value }
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      unless parsed_color = color
        error.puts "Missing required option: --color"
        return
      end

      QuadletInvocation.new(color: parsed_color, output_dir: output_dir, file: file)
    rescue ex : ParseError | ArgumentError
      error.puts ex.message || "Invalid quadlet arguments"
      nil
    end

    private def self.run_status(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      return print_status_help(output) if help_requested?(args)

      invocation = parse_file_invocation(args, error, "Invalid status arguments")
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      Commands::Status.new(config, ssh_executor: ssh_executor, output: output, error: error).run
      0
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError
      error.puts ex.message || "Status failed"
      1
    end

    private def self.run_logs(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      return print_logs_help(output) if help_requested?(args)

      invocation = parse_logs_invocation(args, error)
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      Commands::Logs.new(config, ssh_executor: ssh_executor, output: output, error: error).run(invocation.host)
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | ArgumentError | SSH::ConnectionError
      error.puts ex.message || "Logs failed"
      1
    end

    private def self.parse_logs_invocation(args : Array(String), error : IO) : LogsInvocation?
      host = nil
      file = "deploy.yml"

      parser = OptionParser.new
      parser.on("--host HOST", "Configured host to stream logs from") { |value| host = value }
      parser.on("--file PATH", "Path to deploy config") { |value| file = value }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      LogsInvocation.new(host: host, file: file)
    rescue ex : ParseError
      error.puts ex.message || "Invalid logs arguments"
      nil
    end

    private def self.run_rollback(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      return print_rollback_help(output) if help_requested?(args)

      invocation = parse_file_invocation(args, error, "Invalid rollback arguments")
      return 1 unless invocation

      config = Config::Loader.load(invocation.file)
      Commands::Rollback.new(config, ssh_executor: ssh_executor, output: output, error: error).run
      0
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | Deploy::RollbackFailed
      error.puts ex.message || "Rollback failed"
      1
    end

    private def self.run_server(
      args : Array(String),
      output : IO,
      error : IO,
      ssh_executor : SSH::Executor,
    ) : Int32
      subcommand = args.first?
      return print_server_help(output) if subcommand.try(&.in?(HELP_FLAGS))

      unless subcommand
        error.puts "Missing server subcommand"
        return 1
      end

      case subcommand
      when "bootstrap"
        return print_server_bootstrap_help(output) if help_requested?(args[1..])

        invocation = parse_server_bootstrap_invocation(args[1..], error)
        return 1 unless invocation

        config = Config::Loader.load(invocation.file)
        Commands::Server.new(config, ssh_executor: ssh_executor, output: output, error: error).bootstrap(invocation)
        0
      else
        error.puts "Unknown server subcommand: #{subcommand}"
        1
      end
    rescue ex : Config::ValidationError | Config::UnknownRole | YAML::ParseException | File::NotFoundError | Server::BootstrapError
      error.puts ex.message || "Server bootstrap failed"
      1
    end

    private def self.parse_server_bootstrap_invocation(args : Array(String), error : IO) : ServerBootstrapInvocation?
      host = nil.as(String?)
      port = nil.as(Int32?)
      root_user = "root"
      deploy_user = nil.as(String?)
      accept_new_host_key = true
      enable_auto_updates = true
      passwordless_sudo = true
      rootless_low_ports = true
      rootless_port_start = 80
      file = "deploy.yml"

      parser = OptionParser.new
      parser.on("--host HOST", "Server IP or hostname (default: inferred when only one host in deploy.yml)") { |v| host = v }
      parser.on("--port PORT", "SSH port used to connect (overrides deploy.yml default)") { |v| port = v.to_i }
      parser.on("--root-user USER", "Initial privileged SSH user (default: root)") { |v| root_user = v }
      parser.on("--deploy-user USER", "User to create (default: from deploy.yml ssh.user)") { |v| deploy_user = v }
      parser.on("--accept-new-host-key", "Use StrictHostKeyChecking=accept-new (default)") { accept_new_host_key = true }
      parser.on("--no-accept-new-host-key", "Use StrictHostKeyChecking=yes") { accept_new_host_key = false }
      parser.on("--enable-auto-updates BOOL", "Enable unattended security updates (default: yes)") do |v|
        enable_auto_updates = parse_bool_flag(v, "--enable-auto-updates")
      end
      parser.on("--passwordless-sudo BOOL", "Passwordless sudo for deploy user (default: yes)") do |v|
        passwordless_sudo = parse_bool_flag(v, "--passwordless-sudo")
      end
      parser.on("--rootless-low-ports BOOL", "Allow rootless low-port binding (default: yes)") do |v|
        rootless_low_ports = parse_bool_flag(v, "--rootless-low-ports")
      end
      parser.on("--rootless-port-start PORT", "Lowest unprivileged port (default: 80)") { |v| rootless_port_start = v.to_i }
      parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| file = v }
      parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
      parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
      parser.unknown_args do |before_dash, after_dash|
        unknown = before_dash + after_dash
        raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
      end

      parser.parse(args.dup)

      ServerBootstrapInvocation.new(
        host: host,
        port: port,
        root_user: root_user,
        deploy_user: deploy_user,
        accept_new_host_key: accept_new_host_key,
        enable_auto_updates: enable_auto_updates,
        passwordless_sudo: passwordless_sudo,
        rootless_low_ports: rootless_low_ports,
        rootless_port_start: rootless_port_start,
        file: file,
      )
    rescue ex : ParseError
      error.puts ex.message || "Invalid server bootstrap arguments"
      nil
    end

    private def self.parse_bool_flag(value : String, flag : String) : Bool
      case value.strip.downcase
      when "1", "true", "yes", "y", "on"  then true
      when "0", "false", "no", "n", "off" then false
      else
        raise ParseError.new("#{flag} must be one of: yes/no, true/false, 1/0")
      end
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
      io.puts "Usage: meridian exec ROLE [options] -- COMMAND [ARGS...]"
      io.puts
      io.puts "Run a command inside the active container for a configured role."
      io.puts
      io.puts "Options:"
      io.puts "    --host HOST                Specific host for the role (default: first configured host)"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_run_help(io : IO) : Int32
      io.puts "Usage: meridian run ROLE [options] -- COMMAND [ARGS...]"
      io.puts
      io.puts "Run a one-off command in an isolated container for a configured role."
      io.puts "Unlike exec, this starts a new container with --rm and does not affect the live service."
      io.puts
      io.puts "Options:"
      io.puts "    --host HOST                Specific host for the role (default: first configured host)"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_accessory_help(io : IO) : Int32
      io.puts "Usage: meridian accessory SUBCOMMAND NAME [options]"
      io.puts
      io.puts "Accessory subcommands:"
      io.puts "    start                      Upload and start an accessory service"
      io.puts "    stop                       Stop an accessory service"
      io.puts "    logs                       Stream logs for an accessory service"
      io.puts
      io.puts "Run `meridian accessory SUBCOMMAND --help` for subcommand options."
      0
    end

    private def self.print_accessory_start_help(io : IO) : Int32
      io.puts "Usage: meridian accessory start NAME [options]"
      io.puts
      io.puts "Upload the accessory Quadlet and start the accessory service."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_accessory_stop_help(io : IO) : Int32
      io.puts "Usage: meridian accessory stop NAME [options]"
      io.puts
      io.puts "Stop the accessory service on its configured host."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_accessory_logs_help(io : IO) : Int32
      io.puts "Usage: meridian accessory logs NAME [options]"
      io.puts
      io.puts "Stream journalctl logs for the accessory service."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_secret_help(io : IO) : Int32
      io.puts "Usage: meridian secret SUBCOMMAND NAME [options]"
      io.puts
      io.puts "Secret subcommands:"
      io.puts "    set                        Create or replace a secret on target hosts"
      io.puts "    rm                         Remove a secret from target hosts"
      io.puts "    ls                         List secrets on target hosts"
      io.puts
      io.puts "Run `meridian secret SUBCOMMAND --help` for subcommand options."
      0
    end

    private def self.print_secret_set_help(io : IO) : Int32
      io.puts "Usage: meridian secret set NAME [options]"
      io.puts
      io.puts "Create or replace a Podman secret on every host in the target role."
      io.puts "When --value is omitted, the secret value is read from stdin."
      io.puts
      io.puts "Options:"
      io.puts "    --value VALUE              Secret value (default: read from stdin)"
      io.puts "    --role ROLE                Target role (default: web)"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_secret_rm_help(io : IO) : Int32
      io.puts "Usage: meridian secret rm NAME [options]"
      io.puts
      io.puts "Remove a Podman secret from every host in the target role."
      io.puts
      io.puts "Options:"
      io.puts "    --role ROLE                Target role (default: web)"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_secret_ls_help(io : IO) : Int32
      io.puts "Usage: meridian secret ls [options]"
      io.puts
      io.puts "List Podman secrets on every host in the target role."
      io.puts
      io.puts "Options:"
      io.puts "    --role ROLE                Target role (default: web)"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_status_help(io : IO) : Int32
      io.puts "Usage: meridian status [options]"
      io.puts
      io.puts "Show blue/green service state for all configured hosts."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_logs_help(io : IO) : Int32
      io.puts "Usage: meridian logs [options]"
      io.puts
      io.puts "Stream journalctl logs for the deployed service."
      io.puts
      io.puts "Options:"
      io.puts "    --host HOST                Configured host to stream logs from"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
      io.puts "    -h, --help                 Show this help"
      0
    end

    private def self.print_rollback_help(io : IO) : Int32
      io.puts "Usage: meridian rollback [options]"
      io.puts
      io.puts "Switch kamal-proxy back to the inactive color on each web host."
      io.puts
      io.puts "Options:"
      io.puts "    --file PATH                Path to deploy config (default: deploy.yml)"
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

    private def self.print_server_help(io : IO) : Int32
      io.puts "Usage: meridian server SUBCOMMAND [options]"
      io.puts
      io.puts "Server subcommands:"
      io.puts "    bootstrap                  Provision a fresh server for Meridian deploys"
      io.puts
      io.puts "Run `meridian server SUBCOMMAND --help` for subcommand options."
      0
    end

    private def self.print_server_bootstrap_help(io : IO) : Int32
      io.puts "Usage: meridian server bootstrap --host HOST [options]"
      io.puts
      io.puts "Provision a fresh Debian/Ubuntu server: installs Podman, UFW, and transfer tools"
      io.puts "for the configured transfer mode, creates the deploy user and rootless directories,"
      io.puts "installs your SSH public key, then hardens SSH."
      io.puts
      io.puts "Options:"
      io.puts "    --host HOST                Server IP or hostname (inferred if only one host in deploy.yml)"
      io.puts "    --port PORT                SSH port (overrides deploy.yml default)"
      io.puts "    --root-user USER           Initial privileged SSH user (default: root)"
      io.puts "    --deploy-user USER         User to create (default: from deploy.yml ssh.user)"
      io.puts "    --accept-new-host-key      Trust new host keys (default)"
      io.puts "    --no-accept-new-host-key   Require known host key"
      io.puts "    --enable-auto-updates BOOL Unattended security updates (default: yes)"
      io.puts "    --passwordless-sudo BOOL   Passwordless sudo for deploy user (default: yes)"
      io.puts "    --rootless-low-ports BOOL  Allow rootless low-port binding (default: yes)"
      io.puts "    --rootless-port-start PORT Lowest unprivileged port (default: 80)"
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
  end
end
