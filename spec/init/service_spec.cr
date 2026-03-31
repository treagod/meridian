require "../spec_helper"

private def run_init_service(
  root : String,
  input_string : String,
  *,
  git_remote : String? = nil,
  force : Bool = false,
) : String
  output = IO::Memory.new
  git_remote_lookup : Proc(String, String?) = ->(_root : String) { git_remote.as(String?) }
  service = Meridian::Init::Service.new(
    root: root,
    input: IO::Memory.new(input_string),
    output: output,
    git_remote_lookup: git_remote_lookup
  )
  service.run(force: force)
  output.to_s
end

describe "Meridian::Init::Service" do
  it "uses the GitHub origin remote to derive the image without prompting for it" do
    with_tempdir do |path|
      output = run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\n\n\n\n",
        git_remote: "git@github.com:acme/myapp.git"
      )

      config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
      config.image.should eq("ghcr.io/acme/myapp")
      config.registry.try(&.server).should eq("ghcr.io")
      config.registry.try(&.username).should eq("acme")
      output.should contain("Git remote: git@github.com:acme/myapp.git")
      output.should_not contain("Image:")
    end
  end

  it "emits a build block when a Dockerfile is present" do
    with_tempdir do |path|
      write_project_file(path, "Dockerfile", "FROM alpine:3.20\n")
      output = run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n"
      )

      config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
      build = config.build || raise "Expected build config"

      build.dockerfile.should eq("Dockerfile")
      build.context.should eq(".")
      output.should contain("Dockerfile present")
    end
  end

  it "does not duplicate .env in .gitignore when it is already present" do
    with_tempdir do |path|
      write_project_file(path, ".gitignore", ".env\nbin/\n")
      output = run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n"
      )

      File.read(File.join(path, ".gitignore")).scan(/^\Q.env\E$/m).size.should eq(1)
      output.should contain(".env already present in .gitignore")
    end
  end

  it "creates a comment-only .env for registry-free transfer modes" do
    with_tempdir do |path|
      run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\nincremental\nghcr.io/acme/myapp\n"
      )

      env_file = File.read(File.join(path, ".env"))
      env_file.should contain("# Fill in secret values used by deploy.yml")
      env_file.should_not contain("REGISTRY_PASSWORD=")
    end
  end

  it "does not write files when prompting aborts early" do
    with_tempdir do |path|
      expect_raises(Meridian::Init::PromptAborted) do
        run_init_service(path, "\n95.216.1.10\n")
      end

      File.exists?(File.join(path, "deploy.yml")).should be_false
      File.exists?(File.join(path, ".env")).should be_false
      File.exists?(File.join(path, ".gitignore")).should be_false
    end
  end
end
