require "../spec_helper"

describe "Meridian::CLI init" do
  it "generates the .meridian/ layout from interactive input" do
    with_tempdir do |path|
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\n\nghcr.io/acme/myapp\nghcr.io\nacme\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(0)
        result.output.should contain("Image:")
        result.output.should contain("Created .meridian/deploy.yml")
        result.output.should contain("Created .meridian/.gitignore")
        result.output.should contain("Created .meridian/hooks/")
        result.output.should contain("Next step: meridian setup")
        result.output.should_not contain(".env")

        config = Meridian::Config::Loader.load(File.join(path, ".meridian/deploy.yml"))
        config.service.should eq(File.basename(path))
        config.image.should eq("ghcr.io/acme/myapp")
        config.servers["web"].hosts.should eq(["95.216.1.10"])
        config.servers["web"].proxy.try(&.host).should eq("myapp.example.com")
        config.proxy.should be_nil
        config.registry.try(&.server).should eq("ghcr.io")
        config.registry.try(&.username).should eq("acme")
        config.build.should be_nil

        File.read(File.join(path, ".meridian/.gitignore")).should eq("secrets\ncache/\ntmp/\n")
        File.exists?(File.join(path, ".env")).should be_false
      end
    end
  end

  it "overwrites .meridian/deploy.yml when --force is passed" do
    with_tempdir do |path|
      write_project_file(path, ".meridian/deploy.yml", "service: old\nimage: old\nservers:\n  web:\n    hosts:\n      - old\n")
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n")

      Dir.cd(path) do
        result = run_cli(["init", "--force"], input: input)

        result.exit_code.should eq(0)

        config = Meridian::Config::Loader.load(File.join(path, ".meridian/deploy.yml"))
        config.image.should eq("ghcr.io/acme/myapp")
        config.transfer.try(&.mode).should eq(Meridian::Config::TransferMode::Stream)
      end
    end
  end

  it "refuses to overwrite .meridian/deploy.yml without --force" do
    with_tempdir do |path|
      deploy_yml = write_project_file(path, ".meridian/deploy.yml", "existing deploy config\n")
      input = IO::Memory.new("\n95.216.1.10\n\nmyapp.example.com\n\nghcr.io/acme/myapp\nghcr.io\nacme\n")

      Dir.cd(path) do
        result = run_cli(["init"], input: input)

        result.exit_code.should eq(1)
        result.output.should contain(".meridian/deploy.yml already exists")
        File.read(deploy_yml).should eq("existing deploy config\n")
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

        config = Meridian::Config::Loader.load(File.join(path, ".meridian/deploy.yml"))
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
        File.exists?(File.join(path, ".meridian/deploy.yml")).should be_false
        File.exists?(File.join(path, ".meridian")).should be_false
      end
    end
  end
end
