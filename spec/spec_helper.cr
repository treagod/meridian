require "file_utils"
require "spec"
require "../src/meridian"

record CLIResult, output : String, exit_code : Int32
record FakeSSHInvocation, command : String, args : Array(String), input : String?
record FakeSSHStreamInvocation, command : String, args : Array(String)
record FakeSSHStreamResult, exit_code : Int32, stdout : String = "", stderr : String = ""

struct FakeSSHInvocation
  def host : String?
    target = target_host
    return unless target

    if separator_index = target.rindex('@')
      target[(separator_index + 1)..]
    else
      target
    end
  end

  def remote_command : String?
    index = target_index
    return unless index

    args[index + 1]?
  end

  private def target_host : String?
    index = target_index
    return unless index

    args[index]?
  end

  private def target_index : Int32?
    index = 0

    while arg = args[index]?
      case arg
      when "-p", "-i", "-J", "-o"
        index += 2
      else
        return index
      end
    end

    nil
  end
end

struct FakeSSHStreamInvocation
  def host : String?
    target = target_host
    return unless target

    if separator_index = target.rindex('@')
      target[(separator_index + 1)..]
    else
      target
    end
  end

  def remote_command : String?
    index = target_index
    return unless index

    args[index + 1]?
  end

  private def target_host : String?
    index = target_index
    return unless index

    args[index]?
  end

  private def target_index : Int32?
    index = 0

    while arg = args[index]?
      case arg
      when "-p", "-i", "-J", "-o"
        index += 2
      else
        return index
      end
    end

    nil
  end
end

class FakeSSHRunner < Meridian::SSH::Executor::Runner
  record PauseRequest, host : String, remote_command : String?, release : Channel(Nil)

  getter invocations = [] of FakeSSHInvocation
  getter invocation_events : Channel(FakeSSHInvocation)
  getter queued_results = [] of Meridian::SSH::Result
  getter queued_results_by_host : Hash(String, Array(Meridian::SSH::Result))
  property next_result : Meridian::SSH::Result = Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: "")

  def initialize
    @invocation_events = Channel(FakeSSHInvocation).new(256)
    @queued_results_by_host = Hash(String, Array(Meridian::SSH::Result)).new do |hash, host|
      hash[host] = [] of Meridian::SSH::Result
    end
    @pause_requests = [] of PauseRequest
  end

  def enqueue_results(*results : Meridian::SSH::Result) : Nil
    @queued_results.concat(results)
  end

  def enqueue_results_for_host(host : String, *results : Meridian::SSH::Result) : Nil
    @queued_results_by_host[host].concat(results)
  end

  def enqueue_results_for_host(host : String, results : Array(Meridian::SSH::Result)) : Nil
    @queued_results_by_host[host].concat(results)
  end

  def pause_next_invocation(host : String, remote_command : String? = nil) : Channel(Nil)
    release = Channel(Nil).new
    @pause_requests << PauseRequest.new(host: host, remote_command: remote_command, release: release)
    release
  end

  def run(command : String, args : Array(String), input : String? = nil) : Meridian::SSH::Result
    invocation = FakeSSHInvocation.new(command: command, args: args.dup, input: input)
    @invocations << invocation
    @invocation_events.send(invocation)

    if pause_request = take_pause_request(invocation)
      pause_request.release.receive
    end

    result_for(invocation)
  end

  private def result_for(invocation : FakeSSHInvocation) : Meridian::SSH::Result
    if host = invocation.host
      if results = @queued_results_by_host[host]?
        return results.shift if results.present?
      end
    end

    @queued_results.shift? || @next_result
  end

  private def take_pause_request(invocation : FakeSSHInvocation) : PauseRequest?
    @pause_requests.each_with_index do |pause_request, index|
      next unless invocation.host == pause_request.host
      next if pause_request.remote_command && invocation.remote_command != pause_request.remote_command

      return @pause_requests.delete_at(index)
    end

    nil
  end
end

class FakeSSHStreamingRunner < Meridian::SSH::Executor::StreamingRunner
  getter invocations = [] of FakeSSHStreamInvocation
  getter invocation_events : Channel(FakeSSHStreamInvocation)
  getter queued_results = [] of FakeSSHStreamResult
  getter queued_results_by_host : Hash(String, Array(FakeSSHStreamResult))
  property next_result : FakeSSHStreamResult = FakeSSHStreamResult.new(exit_code: 0)

  def initialize
    @invocation_events = Channel(FakeSSHStreamInvocation).new(256)
    @queued_results_by_host = Hash(String, Array(FakeSSHStreamResult)).new do |hash, host|
      hash[host] = [] of FakeSSHStreamResult
    end
  end

  def enqueue_results(*results : FakeSSHStreamResult) : Nil
    @queued_results.concat(results)
  end

  def enqueue_results_for_host(host : String, *results : FakeSSHStreamResult) : Nil
    @queued_results_by_host[host].concat(results)
  end

  def enqueue_results_for_host(host : String, results : Array(FakeSSHStreamResult)) : Nil
    @queued_results_by_host[host].concat(results)
  end

  def run(command : String, args : Array(String), input : IO, output : IO, error : IO) : Int32
    invocation = FakeSSHStreamInvocation.new(command: command, args: args.dup)
    @invocations << invocation
    @invocation_events.send(invocation)

    result = result_for(invocation)
    output << result.stdout
    error << result.stderr
    result.exit_code
  end

  private def result_for(invocation : FakeSSHStreamInvocation) : FakeSSHStreamResult
    if host = invocation.host
      if results = @queued_results_by_host[host]?
        return results.shift if results.present?
      end
    end

    @queued_results.shift? || @next_result
  end
end

class FakeDeployOrchestrator < Meridian::Deploy::Orchestrator
  getter deploy_calls = 0
  getter deploy_targets : Array(Meridian::CLI::TargetSelector::Target)? = nil
  property deploy_error : Meridian::Deploy::DeployFailed?

  def initialize(
    config : Meridian::Config::DeployConfig,
    @deploy_error : Meridian::Deploy::DeployFailed? = nil,
    output : IO = IO::Memory.new,
  )
    super(
      config,
      ssh_executor: Meridian::SSH::Executor.new(runner: FakeSSHRunner.new),
      quadlet_generator: Meridian::Quadlet::Generator.new(config),
      output: output
    )
  end

  def deploy(targets : Array(Meridian::CLI::TargetSelector::Target)? = nil) : Nil
    @deploy_calls += 1
    @deploy_targets = targets
    if error = @deploy_error
      raise error
    end
  end
end

class FakeIncrementalTransfer < Meridian::Transfer::Incremental
  getter transfer_calls = [] of NamedTuple(host: String, image: String)
  property transfer_error : Meridian::Transfer::TransferFailed?

  def initialize(
    @transfer_error : Meridian::Transfer::TransferFailed? = nil,
    output : IO = IO::Memory.new,
  )
    super(
      "test-service",
      Meridian::SSH::Executor.new(runner: FakeSSHRunner.new),
      output: output
    )
  end

  def transfer(host : String, image : String) : Nil
    @transfer_calls << {host: host, image: image}
    if error = @transfer_error
      raise error
    end
  end
end

class FakeProxyManager < Meridian::Proxy::Manager
  getter setup_calls = 0
  getter remove_calls = 0
  property setup_error : Meridian::Proxy::SetupFailed?
  property remove_error : Meridian::Proxy::RemoveFailed?

  def initialize(
    config : Meridian::Config::DeployConfig,
    @setup_error : Meridian::Proxy::SetupFailed? = nil,
    @remove_error : Meridian::Proxy::RemoveFailed? = nil,
    output : IO = IO::Memory.new,
  )
    super(
      config,
      ssh_executor: Meridian::SSH::Executor.new(runner: FakeSSHRunner.new),
      quadlet_generator: Meridian::Quadlet::Generator.new(config),
      output: output
    )
  end

  def setup : Nil
    @setup_calls += 1
    if error = @setup_error
      raise error
    end
  end

  def remove : Nil
    @remove_calls += 1
    if error = @remove_error
      raise error
    end
  end
end

record FakeBootstrapInvocation,
  command : String,
  args : Array(String),
  step : String,
  interactive : Bool

class FakeBootstrapRunner < Meridian::Server::Bootstrapper::Runner
  getter invocations = [] of FakeBootstrapInvocation
  @check_results = [] of Bool

  def enqueue_check(result : Bool) : Nil
    @check_results << result
  end

  def run_interactive(command : String, args : Array(String), step : String) : Nil
    @invocations << FakeBootstrapInvocation.new(command: command, args: args.dup, step: step, interactive: true)
  end

  def run_check(command : String, args : Array(String), step : String) : Bool
    @invocations << FakeBootstrapInvocation.new(command: command, args: args.dup, step: step, interactive: false)
    result = @check_results.shift?
    result.nil? ? true : result
  end
end

def run_cli(
  args : Array(String),
  *,
  input : IO = IO::Memory.new(""),
  ssh_executor : Meridian::SSH::Executor = Meridian::SSH::Executor.new,
  orchestrator_factory : Meridian::CLI::OrchestratorFactory = Meridian::CLI::DEFAULT_ORCHESTRATOR_FACTORY,
  proxy_manager_factory : Meridian::CLI::ProxyManagerFactory = Meridian::CLI::DEFAULT_PROXY_MANAGER_FACTORY,
) : CLIResult
  io = IO::Memory.new
  exit_code = Meridian::CLI.run(
    args,
    input: input,
    output: io,
    error: io,
    ssh_executor: ssh_executor,
    orchestrator_factory: orchestrator_factory,
    proxy_manager_factory: proxy_manager_factory
  )
  CLIResult.new(output: io.to_s, exit_code: exit_code)
end

def ssh_ok(stdout : String = "") : Meridian::SSH::Result
  Meridian::SSH::Result.new(exit_code: 0, stdout: stdout, stderr: "")
end

def remote_commands_for(runner : FakeSSHRunner, host : String? = nil) : Array(String)
  invocations =
    if host
      runner.invocations.select { |invocation| invocation.host == host }
    else
      runner.invocations
    end

  invocations.compact_map(&.remote_command)
end

def write_config(content : String) : String
  path = File.join(Dir.tempdir, "deploy_#{Random::Secure.hex(8)}.yml")
  File.write(path, content)
  path
end

def load_config(content : String) : Meridian::Config::DeployConfig
  Meridian::Config::Loader.load(write_config(content))
end

def with_tempdir(& : String ->)
  path = File.join(Dir.tempdir, "meridian_spec_#{Random::Secure.hex(8)}")
  Dir.mkdir_p(path)
  yield path
ensure
  FileUtils.rm_rf(path) if path
end

def write_project_file(root : String, relative_path : String, content : String) : String
  path = File.join(root, relative_path)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
  path
end

MINIMAL_CONFIG = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest

    registry:
      server: registry.example.com
      username: deploy
      password:
        - REGISTRY_PASSWORD

    env:
      clear:
        RAILS_ENV: production
  YAML

FULL_CONFIG = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10
          - 192.168.1.11
        proxy:
          host: myapp.example.com
          ssl: true
          healthcheck:
            path: /health
            interval: 2
            timeout: 5
            retries: 10
      workers:
        hosts:
          - 192.168.1.12
        cmd: bin/sidekiq

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest

    env:
      clear:
        RAILS_ENV: production
        DATABASE_HOST: db.internal
      secret:
        - SECRET_KEY_BASE
        - DATABASE_URL

    ssh:
      user: deploy
      port: 22

    boot:
      limit: 1
      wait: 10

    accessories:
      db:
        image: docker.io/library/postgres:16
        host: 192.168.1.20
        port: "5432:5432"
        volumes:
          - pgdata:/var/lib/postgresql/data
        env:
          secret:
            - POSTGRES_PASSWORD
  YAML

FULL_CONFIG_WITH_KEYS = <<-YAML
    service: myapp
    image: registry.example.com/myorg/myapp

    servers:
      web:
        hosts:
          - 192.168.1.10

    proxy:
      image: ghcr.io/basecamp/kamal-proxy:latest

    registry:
      server: registry.example.com
      username: deploy
      password:
        - REGISTRY_PASSWORD

    ssh:
      user: deploy
      port: 2222
      keys:
        - /tmp/meridian_test_key
  YAML
