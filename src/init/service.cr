require "yaml"

module Meridian
  module Init
    DEFAULT_PROXY_IMAGE = "ghcr.io/basecamp/kamal-proxy:latest"

    enum TransferChoice
      Registry
      Stream
      Incremental

      def slug : String
        to_s.downcase
      end
    end

    record DetectedProject,
      service_name : String,
      git_remote : String?,
      image_suggestion : String?,
      framework : DetectedFramework?,
      dockerfile_present : Bool

    record Answers,
      service_name : String,
      image : String,
      server_host : String,
      ssh_user : String,
      public_hostname : String,
      transfer_mode : TransferChoice,
      registry_server : String?,
      registry_username : String?,
      clear_env : Hash(String, String),
      healthcheck_path : String?,
      dockerfile_present : Bool

    class Service
      def initialize(
        root : String = Dir.current,
        input : IO = STDIN,
        output : IO = STDOUT,
        framework_detector : FrameworkDetector? = nil,
        git_remote_lookup : Proc(String, String?)? = nil,
      )
        @root = root
        @input = input
        @output = output
        @framework_detector = framework_detector || FrameworkDetector.new(@root)
        default_git_remote_lookup : Proc(String, String?) = ->(project_root : String) { self.class.lookup_git_remote(project_root) }
        @git_remote_lookup = git_remote_lookup || default_git_remote_lookup
      end

      def run(*, force : Bool = false) : Nil
        detected = detect_project
        print_detection_summary(detected)
        answers = collect_answers(detected)

        deploy_yml_path = root_path("deploy.yml")
        env_path = root_path(".env")
        gitignore_path = root_path(".gitignore")

        preflight!(deploy_yml_path, env_path, force)

        deploy_yml = render_deploy_yml(answers)
        validate_deploy_yml!(deploy_yml)
        env_file = render_env_file(answers)

        File.write(deploy_yml_path, deploy_yml)
        File.write(env_path, env_file)
        gitignore_result = update_gitignore(gitignore_path)

        @output.puts "Created deploy.yml"
        @output.puts "Created .env  (fill in the secret values before deploying)"
        case gitignore_result
        when :created
          @output.puts "Created .gitignore and added .env"
        when :added
          @output.puts "Added .env to .gitignore"
        when :unchanged
          @output.puts ".env already present in .gitignore"
        end
        @output.puts
        @output.puts "Next step: meridian setup"
      rescue ex : Config::ValidationError | YAML::ParseException
        raise GenerationError.new("Generated deploy.yml is invalid: #{ex.message || ex.class.name}")
      end

      def self.lookup_git_remote(root : String) : String?
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run("git", ["config", "--get", "remote.origin.url"], chdir: root, output: stdout, error: stderr)
        return unless status.success?

        remote = stdout.to_s.strip
        remote.empty? ? nil : remote
      rescue ex : File::Error
        nil
      end

      private def detect_project : DetectedProject
        git_remote = @git_remote_lookup.call(@root)

        DetectedProject.new(
          service_name: File.basename(@root),
          git_remote: git_remote,
          image_suggestion: image_from_git_remote(git_remote),
          framework: @framework_detector.detect,
          dockerfile_present: File.file?(root_path("Dockerfile"))
        )
      end

      private def print_detection_summary(detected : DetectedProject) : Nil
        details = [] of String
        if framework = detected.framework
          details << "#{framework.name} app"
        end
        if detected.dockerfile_present
          details << "Dockerfile present"
        end

        unless details.empty?
          @output.puts "Detected: #{details.join(", ")}"
        end

        if git_remote = detected.git_remote
          @output.puts "Git remote: #{git_remote}"
        end

        if note = detected.framework.try(&.note)
          @output.puts "Note: #{note}"
        end

        @output.puts
      end

      private def collect_answers(detected : DetectedProject) : Answers
        service_name = prompt("Service name", default: detected.service_name, required: true)
        server_host = prompt("Server IP or hostname", required: true)
        ssh_user = prompt("SSH user", default: "deploy", required: true)
        public_hostname = prompt("Public hostname", required: true)
        transfer_mode = prompt_transfer_mode

        image = detected.image_suggestion || prompt("Image", required: true)
        registry_server = nil.as(String?)
        registry_username = nil.as(String?)

        if transfer_mode.registry?
          registry_defaults = registry_defaults_for_image(image)
          registry_server = prompt("Registry server", default: registry_defaults[0], required: true)
          registry_username = prompt("Registry username", default: registry_defaults[1], required: true)
        end

        framework = detected.framework

        Answers.new(
          service_name: service_name,
          image: image,
          server_host: server_host,
          ssh_user: ssh_user,
          public_hostname: public_hostname,
          transfer_mode: transfer_mode,
          registry_server: registry_server,
          registry_username: registry_username,
          clear_env: framework.try(&.clear_env) || EMPTY_ENV,
          healthcheck_path: framework.try(&.healthcheck_path),
          dockerfile_present: detected.dockerfile_present
        )
      end

      private def prompt(label : String, *, default : String? = nil, required : Bool = false) : String
        loop do
          if default
            @output.print "#{label} [#{default}]: "
          else
            @output.print "#{label}: "
          end

          raw_value = @input.gets
          raise PromptAborted.new("Input ended before #{label.downcase} was provided") unless raw_value

          value = raw_value.strip
          return default if value.empty? && default
          return value unless value.empty?

          if required
            @output.puts "#{label} is required."
            next
          end

          return value
        end
      end

      private def prompt_transfer_mode : TransferChoice
        @output.puts "Transfer modes:"
        @output.puts "  registry     Push/pull through a container registry"
        @output.puts "  stream       Pipe the image over SSH with zstd; no registry"
        @output.puts "  incremental  Sync OCI layers over SSH; no registry"

        loop do
          @output.print "Transfer mode [registry]: "
          raw_value = @input.gets
          raise PromptAborted.new("Input ended before transfer mode was provided") unless raw_value

          value = raw_value.strip
          value = "registry" if value.empty?

          case value
          when "registry"
            return TransferChoice::Registry
          when "stream"
            return TransferChoice::Stream
          when "incremental"
            return TransferChoice::Incremental
          else
            @output.puts "Invalid transfer mode: #{value}"
          end
        end
      end

      private def preflight!(deploy_yml_path : String, env_path : String, force : Bool) : Nil
        return if force

        if File.exists?(deploy_yml_path)
          raise OverwriteRefused.new("deploy.yml already exists. Use --force to overwrite it.")
        end
        if File.exists?(env_path)
          raise OverwriteRefused.new(".env already exists. Use --force to overwrite it.")
        end
      end

      private def validate_deploy_yml!(content : String) : Nil
        Config::Loader.parse(content)
      end

      private def render_deploy_yml(answers : Answers) : String
        YAML.build do |yaml|
          yaml.mapping do
            write_scalar_field(yaml, "service", answers.service_name)
            write_scalar_field(yaml, "image", answers.image)

            if answers.dockerfile_present
              yaml.scalar "build"
              yaml.mapping do
                write_scalar_field(yaml, "dockerfile", "Dockerfile")
                write_scalar_field(yaml, "context", ".")
              end
            end

            yaml.scalar "servers"
            yaml.mapping do
              yaml.scalar "web"
              yaml.mapping do
                yaml.scalar "hosts"
                yaml.sequence do
                  yaml.scalar answers.server_host
                end

                yaml.scalar "proxy"
                yaml.mapping do
                  write_scalar_field(yaml, "host", answers.public_hostname)
                  if healthcheck_path = answers.healthcheck_path
                    yaml.scalar "healthcheck"
                    yaml.mapping do
                      write_scalar_field(yaml, "path", healthcheck_path)
                    end
                  end
                end
              end
            end

            yaml.scalar "proxy"
            yaml.mapping do
              write_scalar_field(yaml, "image", DEFAULT_PROXY_IMAGE)
            end

            case answers.transfer_mode
            when .registry?
              yaml.scalar "registry"
              yaml.mapping do
                write_scalar_field(yaml, "server", answers.registry_server || "")
                write_scalar_field(yaml, "username", answers.registry_username || "")
                yaml.scalar "password"
                yaml.sequence do
                  yaml.scalar "REGISTRY_PASSWORD"
                end
              end
            else
              yaml.scalar "transfer"
              yaml.mapping do
                write_scalar_field(yaml, "mode", answers.transfer_mode.slug)
              end
            end

            unless answers.clear_env.empty?
              yaml.scalar "env"
              yaml.mapping do
                yaml.scalar "clear"
                yaml.mapping do
                  answers.clear_env.each do |key, value|
                    write_scalar_field(yaml, key, value)
                  end
                end
              end
            end

            unless answers.ssh_user == "deploy"
              yaml.scalar "ssh"
              yaml.mapping do
                write_scalar_field(yaml, "user", answers.ssh_user)
              end
            end
          end
        end
      end

      private def render_env_file(answers : Answers) : String
        secret_names = [] of String
        if answers.transfer_mode.registry?
          secret_names << "REGISTRY_PASSWORD"
        end

        String.build do |io|
          io.puts "# Fill in secret values used by deploy.yml"
          secret_names.uniq.sort.each do |name|
            io.puts "#{name}="
          end
        end
      end

      private def update_gitignore(path : String) : Symbol
        content =
          if File.exists?(path)
            File.read(path)
          else
            ""
          end

        lines = content.lines(chomp: true)
        return :unchanged if lines.includes?(".env")

        updated_content = String.build do |io|
          io << content
          if !content.empty? && !content.ends_with?('\n')
            io.puts
          end
          io.puts ".env"
        end

        File.write(path, updated_content)
        content.empty? ? :created : :added
      end

      private def image_from_git_remote(remote : String?) : String?
        return unless remote

        if match = /github\.com[:\/]([^\/]+)\/([^\/]+?)(?:\.git)?$/.match(remote)
          owner = match[1]
          repo = match[2]
          return "ghcr.io/#{owner}/#{repo}"
        end

        nil
      end

      private def registry_defaults_for_image(image : String) : {String?, String?}
        parts = image.split("/")
        return {nil, nil} if parts.size < 2

        first_part = parts.first
        return {nil, nil} unless registry_host?(first_part)

        {first_part, parts[1]?}
      end

      private def registry_host?(value : String) : Bool
        value.includes?('.') || value.includes?(':') || value == "localhost"
      end

      private def write_scalar_field(yaml : YAML::Builder, key : String, value : String) : Nil
        yaml.scalar key
        yaml.scalar value
      end

      private def root_path(relative_path : String) : String
        File.join(@root, relative_path)
      end

      private EMPTY_ENV = {} of String => String
    end
  end
end
