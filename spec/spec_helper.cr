require "file_utils"
require "spec"
require "../src/meridian"

record CLIResult, output : String, exit_code : Int32
record FakeSSHInvocation, command : String, args : Array(String), input : String?

class FakeSSHRunner < Meridian::SSH::Executor::Runner
  getter invocations = [] of FakeSSHInvocation
  getter queued_results = [] of Meridian::SSH::Result
  property next_result : Meridian::SSH::Result = Meridian::SSH::Result.new(exit_code: 0, stdout: "", stderr: "")

  def enqueue_results(*results : Meridian::SSH::Result) : Nil
    @queued_results.concat(results)
  end

  def run(command : String, args : Array(String), input : String? = nil) : Meridian::SSH::Result
    @invocations << FakeSSHInvocation.new(command: command, args: args.dup, input: input)
    @queued_results.shift? || @next_result
  end
end

class FakeDeployOrchestrator < Meridian::Deploy::Orchestrator
  getter deploy_calls = 0
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

  def deploy : Nil
    @deploy_calls += 1
    if error = @deploy_error
      raise error
    end
  end
end

def run_cli(
  args : Array(String),
  *,
  ssh_executor : Meridian::SSH::Executor = Meridian::SSH::Executor.new,
  orchestrator_factory : Meridian::CLI::OrchestratorFactory = Meridian::CLI::DEFAULT_ORCHESTRATOR_FACTORY,
) : CLIResult
  io = IO::Memory.new
  exit_code = Meridian::CLI.run(
    args,
    output: io,
    error: io,
    ssh_executor: ssh_executor,
    orchestrator_factory: orchestrator_factory
  )
  CLIResult.new(output: io.to_s, exit_code: exit_code)
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

  registry:
    server: registry.example.com
    username: deploy
    password:
      - REGISTRY_PASSWORD

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
