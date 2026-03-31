require "../spec_helper"

DEFAULT_MARTEN_ROUTES = <<-CRYSTAL
  Marten.routes.draw do
    path "/", HomeHandler, name: "home"
  end
CRYSTAL

DEFAULT_RAILS_ROUTES = <<-RUBY
  Rails.application.routes.draw do
  end
RUBY

private def write_marten_project(root : String, routes_content : String = DEFAULT_MARTEN_ROUTES)
  write_project_file(root, "manage.cr", "require \"./src/cli\"\n\nMarten.setup\nMarten::CLI.run\n")
  write_project_file(root, "src/project.cr", "require \"marten\"\n")
  write_project_file(root, "src/server.cr", "require \"./project\"\n\nMarten.start\n")
  write_project_file(root, "config/routes.cr", routes_content)
  write_project_file(root, "config/settings/base.cr", "Marten.configure do |config|\nend\n")
end

private def write_rails_project(root : String, routes_content : String = DEFAULT_RAILS_ROUTES)
  write_project_file(root, "Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
  write_project_file(root, "config.ru", "require_relative \"config/environment\"\nrun Rails.application\n")
  write_project_file(root, "config/routes.rb", routes_content)
end

describe "Meridian::Init::FrameworkDetector" do
  it "detects Marten apps from the expected project layout" do
    with_tempdir do |path|
      write_marten_project(path)

      framework = Meridian::Init::FrameworkDetector.new(path).detect || raise "Expected framework"

      framework.name.should eq("Marten")
      framework.clear_env.should eq({"MARTEN_ENV" => "production"})
      framework.healthcheck_path.should be_nil
      framework.note.not_nil!.should contain("/health")
    end
  end

  it "detects an explicit Marten /health route" do
    with_tempdir do |path|
      write_marten_project(path, <<-CRYSTAL)
          Marten.routes.draw do
            path "/health", HealthHandler, name: "health"
          end
        CRYSTAL

      framework = Meridian::Init::FrameworkDetector.new(path).detect || raise "Expected framework"

      framework.name.should eq("Marten")
      framework.healthcheck_path.should eq("/health")
      framework.note.should be_nil
    end
  end

  it "detects Rails apps from repo-root markers" do
    with_tempdir do |path|
      write_rails_project(path)

      framework = Meridian::Init::FrameworkDetector.new(path).detect || raise "Expected framework"

      framework.name.should eq("Rails")
      framework.clear_env.should eq({"RAILS_ENV" => "production"})
      framework.healthcheck_path.should be_nil
      framework.note.not_nil!.should contain("/health")
    end
  end

  it "detects an explicit Rails /up route" do
    with_tempdir do |path|
      write_rails_project(path, <<-RUBY)
          Rails.application.routes.draw do
            get "/up", to: "health#show"
          end
        RUBY

      framework = Meridian::Init::FrameworkDetector.new(path).detect || raise "Expected framework"

      framework.name.should eq("Rails")
      framework.healthcheck_path.should eq("/up")
      framework.note.should be_nil
    end
  end

  it "prefers Marten over other repo-root markers" do
    with_tempdir do |path|
      write_marten_project(path)
      write_project_file(path, "package.json", %({"name":"demo"}))

      framework = Meridian::Init::FrameworkDetector.new(path).detect || raise "Expected framework"

      framework.name.should eq("Marten")
    end
  end

  it "does not treat nested .ruby-lsp Gemfiles as Rails" do
    with_tempdir do |path|
      write_project_file(path, ".ruby-lsp/Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")
      write_project_file(path, "config.ru", "run App\n")

      framework = Meridian::Init::FrameworkDetector.new(path).detect

      framework.should be_nil
    end
  end

  it "ignores hidden tool directories when looking for framework markers" do
    with_tempdir do |path|
      write_project_file(path, ".venv/package.json", %({"name":"ignored"}))
      write_project_file(path, ".ruby-lsp/Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")

      framework = Meridian::Init::FrameworkDetector.new(path).detect

      framework.should be_nil
    end
  end
end
