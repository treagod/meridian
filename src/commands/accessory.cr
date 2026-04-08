module Meridian
  module Commands
    class Accessory < Base
      def initialize(
        config : Config::DeployConfig,
        ssh_executor : SSH::Executor = SSH::Executor.new,
        quadlet_generator : Quadlet::Generator? = nil,
        output : IO = STDOUT,
        error : IO = STDERR,
      )
        super(config, ssh_executor: ssh_executor, output: output, error: error)
        @quadlet_generator = quadlet_generator || Quadlet::Generator.new(config)
      end

      def start(name : String) : Nil
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)
        container_file = @quadlet_generator.accessory_container_file(name, accessory)

        log(host, "Ensuring Quadlet directory exists")
        run_ssh!(host, ["mkdir", "-p", Quadlet::DIRECTORY])

        log(host, "Uploading accessory Quadlet")
        upload_ssh(host, accessory_quadlet_path(name), container_file)

        log(host, "Reloading user systemd")
        run_ssh!(host, ["systemctl", "--user", "daemon-reload"])

        log(host, "Starting #{accessory_service_unit(name)}")
        run_ssh!(host, ["systemctl", "--user", "start", accessory_service_unit(name)])
      end

      def stop(name : String) : Nil
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)

        log(host, "Stopping #{accessory_service_unit(name)}")
        run_ssh!(host, ["systemctl", "--user", "stop", accessory_service_unit(name)])
      end

      def logs(name : String) : Int32
        accessory = accessory_config(name)
        host = accessory_host(name, accessory)

        stream_ssh(host, ["journalctl", "--user", "-u", accessory_service_unit(name), "-f", "--no-pager"])
      end

      private def log(host : String, message : String) : Nil
        @output.puts "[#{host}] #{message}"
      end
    end
  end
end
