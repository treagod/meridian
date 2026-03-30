module Meridian
  module Deploy
    class Orchestrator
      QUADLET_DIRECTORY = ".config/containers/systemd"
      DEFAULT_COLOR     = Quadlet::Color::Green

      def initialize(
        @config : Config::DeployConfig,
        @ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        @output : IO = STDOUT,
      )
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(@config)
      end

      def deploy_to_host(
        host : String,
        role : String,
        color : Quadlet::Color = DEFAULT_COLOR,
      ) : Nil
        server = @config.servers[role]? || raise Config::UnknownRole.new("Unknown role: #{role}")
        service_name = service_name(color)
        service_unit = "#{service_name}.service"
        network_file = @quadlet_generator.network_file
        container_file = @quadlet_generator.container_file(server, color)

        log(host, "Pulling image #{@config.image}")
        @ssh_executor.run!(host, ["podman", "pull", @config.image])

        log(host, "Ensuring Quadlet directory exists")
        @ssh_executor.run!(host, ["mkdir", "-p", QUADLET_DIRECTORY])

        log(host, "Uploading network Quadlet")
        @ssh_executor.upload(host, File.join(QUADLET_DIRECTORY, "#{@config.service}.network"), network_file)

        log(host, "Uploading service Quadlet")
        @ssh_executor.upload(host, File.join(QUADLET_DIRECTORY, "#{service_name}.container"), container_file)

        log(host, "Reloading user systemd")
        @ssh_executor.run!(host, ["systemctl", "--user", "daemon-reload"])

        active_service = @ssh_executor.run(host, ["systemctl", "--user", "is-active", service_unit])
        if active_service.exit_code.zero?
          log(host, "Stopping existing service #{service_unit}")
          @ssh_executor.run!(host, ["systemctl", "--user", "stop", service_unit])
        end

        log(host, "Starting service #{service_unit}")
        @ssh_executor.run!(host, ["systemctl", "--user", "start", service_unit])
      rescue ex : SSH::CommandFailed | SSH::ConnectionError
        raise DeployFailed.new(ex.message || "Deploy to #{host} failed")
      end

      def deploy : Nil
        web_server = @config.servers["web"]? || raise Config::UnknownRole.new("Unknown role: web")
        host = web_server.hosts.first? || raise DeployFailed.new("No hosts configured for role: web")

        @output.puts "Deploying #{@config.service} to #{host}"
        deploy_to_host(host, "web")
        @output.puts "Deploy completed on #{host}"
      end

      private def service_name(color : Quadlet::Color) : String
        "#{@config.service}-#{color.slug}"
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
