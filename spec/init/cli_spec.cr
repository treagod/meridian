require "../spec_helper"

describe "Meridian::CLI init" do
  it "generates deploy.yml, .env, and .gitignore entries from interactive input" do
    with_tempdir do |path|
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\n\nghcr.io/acme/myapp\nghcr.io\nacme\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(0)
        result.output.should contain("Image:")
        result.output.should contain("Created deploy.yml")
        result.output.should contain("Created .env")
        result.output.should contain("Next step: meridian setup")

        config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
        config.service.should eq(File.basename(path))
        config.image.should eq("ghcr.io/acme/myapp")
        config.servers["web"].hosts.should eq(["95.216.1.10"])
        config.servers["web"].proxy.try(&.host).should eq("myapp.example.com")
        config.proxy.try(&.image).should eq("ghcr.io/basecamp/kamal-proxy:latest")
        config.registry.try(&.server).should eq("ghcr.io")
        config.registry.try(&.username).should eq("acme")
        config.build.should be_nil

        File.read(File.join(path, ".env")).should contain("REGISTRY_PASSWORD=")
        File.read(File.join(path, ".gitignore")).should contain(".env")
      end
    end
  end

  it "overwrites deploy.yml and .env when --force is passed" do
    with_tempdir do |path|
      write_project_file(path, "deploy.yml", "service: old\nimage: old\nservers:\n  web:\n    hosts:\n      - old\n")
      write_project_file(path, ".env", "OLD_SECRET=value\n")
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n")

      Dir.cd(path) do
        result = run_cli(["init", "--force"], input: input)

        result.exit_code.should eq(0)

        config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
        config.image.should eq("ghcr.io/acme/myapp")
        config.transfer.try(&.mode).should eq(Meridian::Config::TransferMode::Stream)
        File.read(File.join(path, ".env")).should_not contain("OLD_SECRET=value")
      end
    end
  end

  it "refuses to overwrite deploy.yml without --force" do
    with_tempdir do |path|
      deploy_yml = write_project_file(path, "deploy.yml", "existing deploy config\n")
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\n\nghcr.io/acme/myapp\nghcr.io\nacme\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(1)
        result.output.should contain("deploy.yml already exists")
        File.read(deploy_yml).should eq("existing deploy config\n")
        File.exists?(File.join(path, ".env")).should be_false
      end
    end
  end

  it "refuses to overwrite .env without --force" do
    with_tempdir do |path|
      env_path = write_project_file(path, ".env", "EXISTING=1\n")
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\n\nghcr.io/acme/myapp\nghcr.io\nacme\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(1)
        result.output.should contain(".env already exists")
        File.read(env_path).should eq("EXISTING=1\n")
        File.exists?(File.join(path, "deploy.yml")).should be_false
      end
    end
  end

  it "re-prompts when the transfer mode is invalid" do
    with_tempdir do |path|
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\nbogus\nstream\nghcr.io/acme/myapp\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(0)
        result.output.should contain("Invalid transfer mode: bogus")

        config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
        config.transfer.try(&.mode).should eq(Meridian::Config::TransferMode::Stream)
      end
    end
  end

  it "aborts without writing files when input ends early" do
    with_tempdir do |path|
      input = IO::Memory.new("\n95.216.1.10\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(1)
        result.output.should contain("Input ended before")
        File.exists?(File.join(path, "deploy.yml")).should be_false
        File.exists?(File.join(path, ".env")).should be_false
      end
    end
  end
end
