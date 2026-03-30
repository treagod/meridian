require "spec"
require "../src/meridian"

record CLIResult, output : String, exit_code : Int32

def run_cli(args : Array(String)) : CLIResult
  io = IO::Memory.new
  exit_code = Meridian::CLI.run(args, output: io, error: io)
  CLIResult.new(output: io.to_s, exit_code: exit_code)
end

def write_config(content : String) : String
  path = File.join(Dir.tempdir, "deploy_#{Random::Secure.hex(8)}.yml")
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
