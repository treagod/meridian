require "yaml"

module Meridian
  module Config
    struct DeployConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter service : String
      getter image : String
      getter build : BuildConfig?
      getter servers : Hash(String, ServerConfig)
      getter proxy : ProxyConfig?
      getter registry : RegistryConfig?
      getter env : EnvConfig?
      getter ssh : SSHConfig = SSHConfig.new
      getter boot : BootConfig = BootConfig.new
      getter transfer : TransferConfig?
      getter accessories : Hash(String, AccessoryConfig)?
      getter volumes : Array(String) = [] of String
      getter ports : Array(String) = [] of String
      getter hooks : HooksConfig?
      getter files : Array(FileSyncConfig) = [] of FileSyncConfig
      getter assets : AssetsConfig?

      protected def after_initialize
        raise ValidationError.new("Config key build is not yet supported") if build
        raise ValidationError.new("Missing required config key: servers") if servers.empty?

        unless /\A[a-zA-Z][a-zA-Z0-9_-]*\z/.matches?(service)
          raise ValidationError.new("Invalid service name #{service.inspect}: must start with a letter and contain only letters, digits, hyphens, and underscores")
        end

        if assets
          unless servers["web"]?.try(&.proxy)
            raise ValidationError.new("assets: requires proxy: to be configured on the web role")
          end
        end

        servers.each do |role, server|
          validate_server_config!(role, server)
        end
      end

      private def validate_server_config!(role : String, server : ServerConfig) : Nil
        if server.managed?
          unless server.units.empty?
            raise ValidationError.new("servers.#{role}.units requires managed: false")
          end
        else
          if server.units.empty?
            raise ValidationError.new("servers.#{role}.units is required when managed: false")
          end

          if server.proxy
            raise ValidationError.new("servers.#{role}.proxy is not supported when managed: false")
          end

          if server.cmd
            raise ValidationError.new("servers.#{role}.cmd is not supported when managed: false")
          end
        end
      end
    end

    struct BuildConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter dockerfile : String = "Dockerfile"
      getter context : String = "."
      getter args : Hash(String, String) = {} of String => String
      getter platform : String?
      getter builder : String?
    end

    struct ServerConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter hosts : Array(String) = [] of String
      getter proxy : ServerProxyConfig?
      getter cmd : String?
      getter image : String?
      getter? managed : Bool = true
      getter units : Array(String) = [] of String
    end

    struct ServerProxyConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter host : String?
      getter? ssl : Bool = false
      getter app_port : Int32 = 3000
      getter healthcheck : HealthcheckConfig = HealthcheckConfig.new
      getter path : String?
    end

    struct ProxyConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter image : String?
      getter http_port : Int32 = 80
      getter https_port : Int32 = 443
      getter data_dir : String = "/var/lib/kamal-proxy"
    end

    struct HealthcheckConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

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
      include YAML::Serializable::Strict

      getter clear : Hash(String, String) = {} of String => String
      getter secret : Array(String) = [] of String
    end

    struct SSHConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

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

      def identity_file : String?
        keys.first?.try { |key| Path[key].expand(home: true).to_s }
      end
    end

    struct BootConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter limit : Int32 = 1
      getter wait : Int32 = 0

      def initialize(@limit : Int32 = 1, @wait : Int32 = 0)
      end
    end

    struct RegistryConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

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
      include YAML::Serializable::Strict

      @[YAML::Field(converter: Meridian::Config::TransferModeConverter)]
      getter mode : TransferMode?

      protected def after_initialize
        raise ValidationError.new("Missing required config key: transfer.mode") unless mode
      end
    end

    struct AccessoryConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter image : String?
      getter host : String?
      getter port : String?
      getter volumes : Array(String) = [] of String
      getter env : EnvConfig?
      getter cmd : String?
      getter network : String?
      getter secrets : Array(String) = [] of String
      getter depends_on : String?
    end

    struct FileSyncConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter source : String
      getter destination : String
      getter? template : Bool = false
      getter roles : Array(String)?
    end

    struct AssetsConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter host : String
      getter command : String
      getter output_dir : String
      getter retain_releases : Int32 = 2
    end

    struct HooksConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter pre_deploy : String?
      getter post_deploy : String?
      getter remote : RemoteHooksConfig?
    end

    struct RemoteHookConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter command : String
      getter roles : Array(String)?
    end

    struct RemoteHooksConfig
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter before_transfer : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter after_transfer : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter after_upload : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter before_start : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter after_start : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter before_switch : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter after_switch : Array(RemoteHookConfig) = [] of RemoteHookConfig
      getter after_deploy : Array(RemoteHookConfig) = [] of RemoteHookConfig
    end

    module Loader
      ROOT_KEYS         = {"service", "image", "build", "servers", "proxy", "registry", "env", "ssh", "boot", "transfer", "accessories", "volumes", "ports", "hooks", "files", "assets"}
      BUILD_KEYS        = {"dockerfile", "context", "args", "platform", "builder"}
      SERVER_KEYS       = {"hosts", "proxy", "cmd", "image", "managed", "units"}
      SERVER_PROXY_KEYS = {"host", "ssl", "app_port", "healthcheck", "path"}
      HEALTHCHECK_KEYS  = {"path", "interval", "timeout", "retries"}
      PROXY_KEYS        = {"image", "http_port", "https_port", "data_dir"}
      REGISTRY_KEYS     = {"server", "username", "password"}
      ENV_KEYS          = {"clear", "secret"}
      SSH_KEYS          = {"user", "port", "keys", "proxy_jump", "connect_timeout", "keepalive", "keepalive_interval"}
      BOOT_KEYS         = {"limit", "wait"}
      TRANSFER_KEYS     = {"mode"}
      ACCESSORY_KEYS    = {"image", "host", "port", "volumes", "env", "cmd", "network", "secrets", "depends_on"}
      HOOKS_KEYS        = {"pre_deploy", "post_deploy", "remote"}
      REMOTE_HOOKS_KEYS = {"before_transfer", "after_transfer", "after_upload", "before_start", "after_start", "before_switch", "after_switch", "after_deploy"}
      REMOTE_HOOK_KEYS  = {"command", "roles"}
      FILE_SYNC_KEYS    = {"source", "destination", "template", "roles"}
      ASSETS_KEYS       = {"host", "command", "output_dir", "retain_releases"}

      def self.load(path : String) : DeployConfig
        parse(File.read(path))
      end

      def self.parse(content : String) : DeployConfig
        if key = unknown_config_key(content)
          raise ValidationError.new("Unknown config key: #{key}")
        end

        DeployConfig.from_yaml(content)
      rescue ex : YAML::ParseException
        message = ex.message || ""
        if match = /Missing YAML attribute: (\w+)/.match(message)
          raise ValidationError.new("Missing required config key: #{match[1]}")
        end

        if match = /Unknown yaml attribute: (.+)/.match(message)
          raise ValidationError.new("Unknown config key: #{match[1]}")
        end

        raise ex
      end

      private def self.unknown_config_key(content : String) : String?
        document = YAML.parse(content)
        root = mapping(document)
        return unless root

        validate_config_mapping(root)
      rescue YAML::ParseException
        nil
      end

      private def self.validate_config_mapping(mapping : Hash(YAML::Any, YAML::Any)) : String?
        if key = unknown_key(mapping, ROOT_KEYS)
          return key
        end

        if build = mapping_value(mapping, "build")
          if build_mapping = mapping(build)
            if key = unknown_key(build_mapping, BUILD_KEYS, "build.")
              return key
            end
          end
        end

        if servers = mapping_value(mapping, "servers")
          if servers_mapping = mapping(servers)
            servers_mapping.each do |role_node, server_node|
              role = scalar(role_node) || next
              server_mapping = mapping(server_node) || next
              if key = unknown_key(server_mapping, SERVER_KEYS, "servers.#{role}.")
                return key
              end

              if proxy = mapping_value(server_mapping, "proxy")
                if proxy_mapping = mapping(proxy)
                  if key = unknown_key(proxy_mapping, SERVER_PROXY_KEYS, "servers.#{role}.proxy.")
                    return key
                  end

                  if healthcheck = mapping_value(proxy_mapping, "healthcheck")
                    if healthcheck_mapping = mapping(healthcheck)
                      if key = unknown_key(healthcheck_mapping, HEALTHCHECK_KEYS, "servers.#{role}.proxy.healthcheck.")
                        return key
                      end
                    end
                  end
                end
              end
            end
          end
        end

        if proxy = mapping_value(mapping, "proxy")
          if proxy_mapping = mapping(proxy)
            if key = unknown_key(proxy_mapping, PROXY_KEYS, "proxy.")
              return key
            end
          end
        end

        if registry = mapping_value(mapping, "registry")
          if registry_mapping = mapping(registry)
            if key = unknown_key(registry_mapping, REGISTRY_KEYS, "registry.")
              return key
            end
          end
        end

        if env = mapping_value(mapping, "env")
          if env_mapping = mapping(env)
            if key = unknown_key(env_mapping, ENV_KEYS, "env.")
              return key
            end
          end
        end

        if ssh = mapping_value(mapping, "ssh")
          if ssh_mapping = mapping(ssh)
            if key = unknown_key(ssh_mapping, SSH_KEYS, "ssh.")
              return key
            end
          end
        end

        if boot = mapping_value(mapping, "boot")
          if boot_mapping = mapping(boot)
            if key = unknown_key(boot_mapping, BOOT_KEYS, "boot.")
              return key
            end
          end
        end

        if transfer = mapping_value(mapping, "transfer")
          if transfer_mapping = mapping(transfer)
            if key = unknown_key(transfer_mapping, TRANSFER_KEYS, "transfer.")
              return key
            end
          end
        end

        if accessories = mapping_value(mapping, "accessories")
          if accessories_mapping = mapping(accessories)
            accessories_mapping.each do |name_node, accessory_node|
              name = scalar(name_node) || next
              accessory_mapping = mapping(accessory_node) || next
              if key = unknown_key(accessory_mapping, ACCESSORY_KEYS, "accessories.#{name}.")
                return key
              end

              if accessory_env = mapping_value(accessory_mapping, "env")
                if accessory_env_mapping = mapping(accessory_env)
                  if key = unknown_key(accessory_env_mapping, ENV_KEYS, "accessories.#{name}.env.")
                    return key
                  end
                end
              end
            end
          end
        end

        if hooks = mapping_value(mapping, "hooks")
          if hooks_mapping = mapping(hooks)
            if key = unknown_key(hooks_mapping, HOOKS_KEYS, "hooks.")
              return key
            end

            if remote = mapping_value(hooks_mapping, "remote")
              if remote_mapping = mapping(remote)
                if key = unknown_key(remote_mapping, REMOTE_HOOKS_KEYS, "hooks.remote.")
                  return key
                end

                remote_mapping.each do |phase_node, phase_value|
                  phase = scalar(phase_node) || next
                  next unless phase_sequence = phase_value.raw.as?(Array(YAML::Any))

                  phase_sequence.each_with_index do |entry, i|
                    if entry_mapping = mapping(entry)
                      if key = unknown_key(entry_mapping, REMOTE_HOOK_KEYS, "hooks.remote.#{phase}[#{i}].")
                        return key
                      end
                    end
                  end
                end
              end
            end
          end
        end

        if files = mapping_value(mapping, "files")
          if files_sequence = files.raw.as?(Array(YAML::Any))
            files_sequence.each_with_index do |entry, i|
              if entry_mapping = mapping(entry)
                if key = unknown_key(entry_mapping, FILE_SYNC_KEYS, "files[#{i}].")
                  return key
                end
              end
            end
          end
        end

        if assets = mapping_value(mapping, "assets")
          if assets_mapping = mapping(assets)
            if key = unknown_key(assets_mapping, ASSETS_KEYS, "assets.")
              return key
            end
          end
        end

        nil
      end

      private def self.unknown_key(
        mapping : Hash(YAML::Any, YAML::Any),
        allowed_keys : Tuple,
        prefix : String = "",
      ) : String?
        mapping.each_key do |key_node|
          key = scalar(key_node) || next
          return "#{prefix}#{key}" unless allowed_keys.includes?(key)
        end

        nil
      end

      private def self.mapping(node : YAML::Any) : Hash(YAML::Any, YAML::Any)?
        node.raw.as?(Hash(YAML::Any, YAML::Any))
      end

      private def self.mapping_value(mapping : Hash(YAML::Any, YAML::Any), wanted_key : String) : YAML::Any?
        mapping.each do |key_node, value_node|
          return value_node if scalar(key_node) == wanted_key
        end

        nil
      end

      private def self.scalar(node : YAML::Any) : String?
        node.raw.as?(String)
      end
    end
  end
end
