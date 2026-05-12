require "../spec_helper"

private def run_plan(content : String) : String
  output = IO::Memory.new
  config = load_config(content)
  Meridian::Commands::Plan.new(config, output: output).run
  output.to_s
end

describe "Meridian::Commands::Plan" do
  describe "#run" do
    it "renders header, single role, and placeholder sections for a minimal config" do
      output = run_plan(MINIMAL_CONFIG)

      output.should contain("service:   myapp")
      output.should contain("image:     registry.example.com/myorg/myapp")
      output.should contain("transfer:  registry")
      output.should contain("ssh user:  deploy")
      output.should contain("registry:  registry.example.com")

      output.should contain("roles:")
      output.should contain("web (managed)")
      output.should contain("hosts:    192.168.1.10")

      output.should contain("clear:    RAILS_ENV=production")
      output.should contain("secrets:  (none)")
      output.should contain("files: (none)")
      output.should contain("hooks: (none)")
      output.should contain("assets: (none)")
      output.should contain("accessories: (none)")
    end

    it "renders every role, proxy line, sorted secrets, and accessory summary for a full config" do
      output = run_plan(FULL_CONFIG)

      output.should contain("transfer:  registry")
      output.should contain("web (managed)")
      output.should contain("hosts:    192.168.1.10, 192.168.1.11")
      output.should contain("proxy:    host=myapp.example.com ssl=true app_port=3000 health=/health")
      output.should contain("workers (managed)")
      output.should contain("cmd:      bin/sidekiq")

      output.should contain("secrets:  DATABASE_URL, SECRET_KEY_BASE")

      output.should contain("accessories:")
      output.should contain("db  image=docker.io/library/postgres:16 host=192.168.1.20 port=5432:5432")
      output.should contain("volumes:  pgdata:/var/lib/postgresql/data")
      output.should contain("secrets:  POSTGRES_PASSWORD")
    end

    it "deduplicates and sorts secret names" do
      content = <<-YAML
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts:
              - 192.168.1.10
        env:
          secret:
            - ZEBRA
            - DATABASE_URL
            - DATABASE_URL
            - ALPHA
        YAML

      output = run_plan(content)
      output.should contain("secrets:  ALPHA, DATABASE_URL, ZEBRA")
    end

    it "labels the transfer mode for stream and incremental modes" do
      stream = <<-YAML
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts:
              - 192.168.1.10
        transfer:
          mode: stream
        YAML

      incremental = stream.sub("stream", "incremental")

      run_plan(stream).should contain("transfer:  stream")
      run_plan(incremental).should contain("transfer:  incremental")
    end

    it "marks unmanaged roles and lists their units without a proxy line" do
      content = <<-YAML
        service: myapp
        image: example.com/myapp
        servers:
          legacy:
            hosts:
              - 192.168.1.50
            managed: false
            units:
              - legacy-app.service
              - legacy-worker.service
        YAML

      output = run_plan(content)
      output.should contain("legacy (unmanaged)")
      output.should contain("units:    legacy-app.service, legacy-worker.service")
      output.should_not contain("proxy:")
    end

    it "never prints secret values, only their names" do
      content = <<-YAML
        service: myapp
        image: example.com/myapp
        servers:
          web:
            hosts:
              - 192.168.1.10
        env:
          clear:
            RAILS_ENV: production
          secret:
            - SUPER_SECRET_VALUE
        YAML

      output = run_plan(content)
      output.should contain("secrets:  SUPER_SECRET_VALUE")
      output.should contain("clear:    RAILS_ENV=production")
    end
  end
end

describe "meridian plan CLI" do
  it "renders the plan without contacting any host" do
    runner = FakeSSHRunner.new
    executor = Meridian::SSH::Executor.new(
      runner: runner,
      streaming_runner: FakeSSHStreamingRunner.new,
    )
    path = write_config(MINIMAL_CONFIG)

    result = run_cli(["plan", "--file", path], ssh_executor: executor)

    result.exit_code.should eq(0)
    result.output.should contain("service:   myapp")
    runner.invocations.should be_empty
  end

  it "returns non-zero and prints the loader error when the file is missing" do
    result = run_cli(["plan", "--file", "/definitely/does/not/exist.yml"])

    result.exit_code.should eq(1)
    result.output.downcase.should contain("no such file")
  end

  it "returns non-zero for invalid YAML and propagates the loader message" do
    path = write_config("service: myapp\nimage: example.com/myapp\n")

    result = run_cli(["plan", "--file", path])

    result.exit_code.should eq(1)
    result.output.should contain("servers")
  end
end
