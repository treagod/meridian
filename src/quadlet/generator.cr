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
        secrets = (@config.env.try(&.secret) || EMPTY_SECRETS).map { |name| "#{name},type=env,target=#{name}" }

        ContainerTemplate.new(
          service: @config.service,
          image: server.image || @config.image,
          color: color,
          environment: environment,
          secrets: secrets,
          volumes: @config.volumes,
          ports: @config.ports,
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
          https_port: proxy.https_port,
          data_dir: proxy.data_dir
        ).to_s
      end

      def accessory_container_file(name : String, accessory : Config::AccessoryConfig) : String
        image = accessory.image || raise ArgumentError.new("Accessory #{name} is missing required image")
        environment = accessory.env.try(&.clear) || EMPTY_ENV
        env_secrets = (accessory.env.try(&.secret) || EMPTY_SECRETS).map { |secret_name| "#{secret_name},type=env,target=#{secret_name}" }
        secrets = env_secrets + accessory.secrets

        AccessoryContainerTemplate.new(
          name: name,
          image: image,
          port: accessory.port,
          volumes: accessory.volumes,
          environment: environment,
          secrets: secrets,
          network: accessory.network,
          depends_on: accessory.depends_on,
          command: accessory.cmd
        ).to_s
      end

      def assets_volume_file : String
        AssetsVolumeTemplate.new.to_s
      end

      def assets_builder_file(release_id : String) : String
        assets = @config.assets || raise ArgumentError.new("Missing assets configuration")
        environment = @config.env.try(&.clear) || EMPTY_ENV
        secrets = (@config.env.try(&.secret) || EMPTY_SECRETS).map { |name| "#{name},type=env,target=#{name}" }

        AssetsBuilderTemplate.new(
          service: @config.service,
          image: @config.image,
          release_id: release_id,
          command: assets.command,
          output_dir: assets.output_dir,
          environment: environment,
          secrets: secrets
        ).to_s
      end

      def assets_server_file : String
        @config.assets || raise ArgumentError.new("Missing assets configuration")

        AssetsServerTemplate.new(service: @config.service).to_s
      end

      def assets_caddy_config : String
        "{\n\tauto_https off\n}\n\n:80 {\n\troot * /srv/assets\n\tfile_server\n}\n"
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

        unless @config.files.empty?
          files_dir = File.join(output_dir, "files")
          Dir.mkdir_p(files_dir)
          @config.files.each do |file_sync|
            content = File.read(file_sync.source)
            content = render_file_sync_template(content) if file_sync.template?
            File.write(File.join(files_dir, File.basename(file_sync.destination)), content)
          end
        end

        if @config.assets
          assets_dir = File.join(output_dir, "assets")
          Dir.mkdir_p(assets_dir)
          File.write(File.join(assets_dir, "#{@config.service}-assets.volume"), assets_volume_file)
          File.write(File.join(assets_dir, "#{@config.service}-assets-builder.container"), assets_builder_file("<RELEASE_ID>"))
          File.write(File.join(assets_dir, "#{@config.service}-assets-server.container"), assets_server_file)
          caddy_dir = File.join(assets_dir, "caddy")
          Dir.mkdir_p(caddy_dir)
          File.write(File.join(caddy_dir, "Caddyfile"), assets_caddy_config)
        end
      end

      private def render_file_sync_template(source : String) : String
        source.gsub(/<%= @config\.(\w+) %>/) do
          case $1
          when "service" then @config.service
          when "image"   then @config.image
          else $~[0]
          end
        end
      end

      private EMPTY_ENV         = {} of String => String
      private EMPTY_SECRETS     = [] of String
      private EMPTY_ACCESSORIES = {} of String => Config::AccessoryConfig

      private class ContainerTemplate
        def initialize(
          @service : String,
          @image : String,
          @color : Color,
          @environment : Hash(String, String),
          @secrets : Array(String),
          @volumes : Array(String),
          @ports : Array(String),
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
          @data_dir : String,
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
          @secrets : Array(String),
          @network : String?,
          @depends_on : String?,
          @command : String?,
        )
        end

        ECR.def_to_s "src/quadlet/templates/accessory_container_file.ecr"
      end

      private class AssetsVolumeTemplate
        ECR.def_to_s "src/quadlet/templates/assets_volume_file.ecr"
      end

      private class AssetsBuilderTemplate
        def initialize(
          @service : String,
          @image : String,
          @release_id : String,
          @command : String,
          @output_dir : String,
          @environment : Hash(String, String),
          @secrets : Array(String),
        )
        end

        ECR.def_to_s "src/quadlet/templates/assets_builder_file.ecr"
      end

      private class AssetsServerTemplate
        def initialize(@service : String)
        end

        ECR.def_to_s "src/quadlet/templates/assets_server_file.ecr"
      end
    end
  end
end
