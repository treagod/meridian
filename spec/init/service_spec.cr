require "../spec_helper"

DEFAULT_INIT_MARTEN_ROUTES = <<-CRYSTAL
  Marten.routes.draw do
    path "/", HomeHandler, name: "home"
  end
  CRYSTAL

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

private def write_init_marten_project(root : String, routes_content : String = DEFAULT_INIT_MARTEN_ROUTES)
  write_project_file(root, "manage.cr", "require \"./src/cli\"\n\nMarten.setup\nMarten::CLI.run\n")
  write_project_file(root, "src/project.cr", "require \"marten\"\n")
  write_project_file(root, "src/server.cr", "require \"./project\"\n\nMarten.start\n")
  write_project_file(root, "config/routes.cr", routes_content)
  write_project_file(root, "config/settings/base.cr", "Marten.configure do |config|\nend\n")
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
      config.proxy.try(&.image).should eq("docker.io/basecamp/kamal-proxy:latest")
      config.registry.try(&.server).should eq("ghcr.io")
      config.registry.try(&.username).should eq("acme")
      output.should contain("Git remote: git@github.com:acme/myapp.git")
      output.should_not contain("Image:")
    end
  end

  it "does not emit a build block when a Dockerfile is present" do
    with_tempdir do |path|
      write_project_file(path, "Dockerfile", "FROM alpine:3.20\n")
      output = run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n"
      )

      config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
      config.build.should be_nil
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

  it "renders Marten proxy app_port and healthcheck defaults" do
    with_tempdir do |path|
      write_init_marten_project(path)

      run_init_service(
        path,
        "\n95.216.1.10\n\nmyapp.example.com\nstream\nghcr.io/acme/myapp\n"
      )

      deploy_yml = File.read(File.join(path, "deploy.yml"))
      deploy_yml.should contain("app_port: 8000")
      deploy_yml.should contain("path: /health")

      config = Meridian::Config::Loader.load(File.join(path, "deploy.yml"))
      proxy = config.servers["web"].proxy || raise "Expected web proxy config"
      proxy.app_port.should eq(8000)
      proxy.healthcheck.path.should eq("/health")
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
