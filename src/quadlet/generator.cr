require "ecr/macros"

module Meridian
  module Quadlet
    DIRECTORY = ".config/containers/systemd"

    enum Color
      Blue
      Green

      def slug : String
        to_s.downcase
      end
    end

    class Generator
      DEFAULT_PROXY_IMAGE = "basecamp/kamal-proxy:v0.9.2"

      def initialize(@config : Config::DeployConfig)
      end

      def container_file(server : Config::ServerConfig, color : Color) : String
        environment = @config.env.try(&.clear) || EMPTY_ENV

        ContainerTemplate.new(
          service: @config.service,
          image: @config.image,
          color: color,
          environment: environment,
          command: server.cmd
        ).to_s
      end

      def network_file : String
        NetworkTemplate.new(service: @config.service).to_s
      end

      def proxy_container_file : String
        proxy = @config.proxy || raise ArgumentError.new("Missing proxy configuration")
        image = proxy.image || DEFAULT_PROXY_IMAGE

        ProxyContainerTemplate.new(
          service: @config.service,
          image: image,
          http_port: proxy.http_port,
          https_port: proxy.https_port
        ).to_s
      end

      def accessory_container_file(name : String, accessory : Config::AccessoryConfig) : String
        image = accessory.image || raise ArgumentError.new("Accessory #{name} is missing required image")
        environment = accessory.env.try(&.clear) || EMPTY_ENV

        AccessoryContainerTemplate.new(
          name: name,
          image: image,
          port: accessory.port,
          volumes: accessory.volumes,
          environment: environment,
          command: accessory.cmd
        ).to_s
      end

      def write_to_directory(output_dir : String, color : Color) : Nil
        web_server = @config.servers["web"]? || raise Config::UnknownRole.new("Unknown role: web")

        Dir.mkdir_p(output_dir)

        File.write(
          File.join(output_dir, "#{@config.service}-#{color.slug}.container"),
          container_file(web_server, color)
        )
        File.write(File.join(output_dir, "#{@config.service}.network"), network_file)

        if @config.proxy
          File.write(File.join(output_dir, "kamal-proxy.container"), proxy_container_file)
        end

        (@config.accessories || EMPTY_ACCESSORIES).each do |name, accessory|
          File.write(File.join(output_dir, "#{name}.container"), accessory_container_file(name, accessory))
        end
      end

      private EMPTY_ENV         = {} of String => String
      private EMPTY_ACCESSORIES = {} of String => Config::AccessoryConfig

      private class ContainerTemplate
        def initialize(
          @service : String,
          @image : String,
          @color : Color,
          @environment : Hash(String, String),
          @command : String?,
        )
        end

        ECR.def_to_s "src/quadlet/templates/container_file.ecr"
      end

      private class NetworkTemplate
        def initialize(@service : String)
        end

        ECR.def_to_s "src/quadlet/templates/network_file.ecr"
      end

      private class ProxyContainerTemplate
        def initialize(
          @service : String,
          @image : String,
          @http_port : Int32,
          @https_port : Int32,
        )
        end

        ECR.def_to_s "src/quadlet/templates/proxy_container_file.ecr"
      end

      private class AccessoryContainerTemplate
        def initialize(
          @name : String,
          @image : String,
          @port : String?,
          @volumes : Array(String),
          @environment : Hash(String, String),
          @command : String?,
        )
        end

        ECR.def_to_s "src/quadlet/templates/accessory_container_file.ecr"
      end
    end
  end
end
