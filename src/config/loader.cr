require "yaml"

module Meridian
  module Config
    struct DeployConfig
      include YAML::Serializable

      getter service : String
      getter image : String
      getter servers : Hash(String, ServerConfig)
      getter proxy : ProxyConfig?
      getter registry : RegistryConfig?
      getter env : EnvConfig?
      getter ssh : SSHConfig = SSHConfig.new
      getter boot : BootConfig = BootConfig.new
      getter transfer : TransferConfig?
      getter accessories : Hash(String, AccessoryConfig)?

      protected def after_initialize
        if servers.empty?
          raise ValidationError.new("Missing required config key: servers")
        end
      end
    end

    struct ServerConfig
      include YAML::Serializable

      getter hosts : Array(String) = [] of String
      getter proxy : ServerProxyConfig?
      getter cmd : String?
      getter replicas : Int32 = 1
    end

    struct ServerProxyConfig
      include YAML::Serializable

      getter host : String?
      getter? ssl : Bool = false
      getter app_port : Int32 = 3000
      getter healthcheck : HealthcheckConfig = HealthcheckConfig.new
      getter path : String?
      getter response_buffer : Int32 = 1_048_576
    end

    struct ProxyConfig
      include YAML::Serializable

      getter image : String?
      getter http_port : Int32 = 80
      getter https_port : Int32 = 443
      getter data_dir : String = "/var/lib/kamal-proxy"
    end

    struct HealthcheckConfig
      include YAML::Serializable

      getter path : String = "/health"
      getter interval : Int32 = 2
      getter timeout : Int32 = 5
      getter retries : Int32 = 10

      def initialize(
        @path : String = "/health",
        @interval : Int32 = 2,
        @timeout : Int32 = 5,
        @retries : Int32 = 10,
      )
      end
    end

    struct EnvConfig
      include YAML::Serializable

      getter clear : Hash(String, String) = {} of String => String
      getter secret : Array(String) = [] of String
    end

    struct SSHConfig
      include YAML::Serializable

      getter user : String = "deploy"
      getter port : Int32 = 22
      getter keys : Array(String) = [] of String
      getter proxy_jump : String?
      getter connect_timeout : Int32 = 10
      getter? keepalive : Bool = true
      getter keepalive_interval : Int32 = 30

      def initialize(
        @user : String = "deploy",
        @port : Int32 = 22,
        @keys : Array(String) = [] of String,
        @proxy_jump : String? = nil,
        @connect_timeout : Int32 = 10,
        @keepalive : Bool = true,
        @keepalive_interval : Int32 = 30,
      )
      end
    end

    struct BootConfig
      include YAML::Serializable

      getter limit : Int32 = 1
      getter wait : Int32 = 0

      def initialize(@limit : Int32 = 1, @wait : Int32 = 0)
      end
    end

    struct RegistryConfig
      include YAML::Serializable

      getter server : String?
      getter username : String?
      getter password : Array(String) = [] of String
    end

    enum TransferMode
      Registry
      Stream
      Incremental
    end

    module TransferModeConverter
      def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : TransferMode?
        return unless node.is_a?(YAML::Nodes::Scalar)
        return if node.value.empty?

        TransferMode.parse?(node.value) ||
          node.raise("Unknown transfer mode: #{node.value.inspect}, expected one of: registry, stream, incremental")
      end

      def self.to_yaml(value : TransferMode?, yaml : YAML::Nodes::Builder)
        yaml.scalar(value.try(&.to_s.downcase) || "")
      end
    end

    struct TransferConfig
      include YAML::Serializable

      @[YAML::Field(converter: Meridian::Config::TransferModeConverter)]
      getter mode : TransferMode?
    end

    struct AccessoryConfig
      include YAML::Serializable

      getter image : String?
      getter host : String?
      getter port : String?
      getter volumes : Array(String) = [] of String
      getter env : EnvConfig?
      getter cmd : String?
    end

    module Loader
      def self.load(path : String) : DeployConfig
        DeployConfig.from_yaml(File.read(path))
      rescue ex : YAML::ParseException
        message = ex.message || ""
        if match = /Missing YAML attribute: (\w+)/.match(message)
          raise ValidationError.new("Missing required config key: #{match[1]}")
        end

        raise ex
      end
    end
  end
end
