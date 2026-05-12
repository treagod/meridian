module Meridian
  module Deploy
    record RolePlan,
      name : String,
      hosts : Array(String),
      image : String,
      managed : Bool,
      cmd : String?,
      units : Array(String),
      proxy : Config::ServerProxyConfig?

    record FilePlan,
      source : String,
      destination : String,
      template : Bool,
      roles : Array(String)?

    record AccessoryPlan,
      name : String,
      image : String?,
      host : String?,
      port : String?,
      volumes : Array(String),
      secrets : Array(String),
      depends_on : String?

    record AssetsPlan,
      host : String,
      command : String,
      output_dir : String,
      retain_releases : Int32

    record HooksPlan,
      pre_deploy : String?,
      post_deploy : String?,
      remote : Array({String, Array(String)}) do
      def empty? : Bool
        pre_deploy.nil? && post_deploy.nil? && remote.empty?
      end
    end

    struct Plan
      getter service : String
      getter default_image : String
      getter transfer_mode : Config::TransferMode?
      getter registry : Config::RegistryConfig?
      getter boot : Config::BootConfig
      getter ssh_user : String
      getter roles : Array(RolePlan)
      getter clear_env : Hash(String, String)
      getter secrets : Array(String)
      getter hooks : HooksPlan
      getter files : Array(FilePlan)
      getter assets : AssetsPlan?
      getter accessories : Array(AccessoryPlan)

      def initialize(
        @service : String,
        @default_image : String,
        @transfer_mode : Config::TransferMode?,
        @registry : Config::RegistryConfig?,
        @boot : Config::BootConfig,
        @ssh_user : String,
        @roles : Array(RolePlan),
        @clear_env : Hash(String, String),
        @secrets : Array(String),
        @hooks : HooksPlan,
        @files : Array(FilePlan),
        @assets : AssetsPlan?,
        @accessories : Array(AccessoryPlan),
      )
      end

      def self.from(config : Config::DeployConfig) : Plan
        new(
          service: config.service,
          default_image: config.image,
          transfer_mode: config.transfer.try(&.mode),
          registry: config.registry,
          boot: config.boot,
          ssh_user: config.ssh.user,
          roles: build_roles(config),
          clear_env: config.env.try(&.clear) || {} of String => String,
          secrets: build_secrets(config),
          hooks: build_hooks(config),
          files: build_files(config),
          assets: build_assets(config),
          accessories: build_accessories(config),
        )
      end

      private def self.build_roles(config : Config::DeployConfig) : Array(RolePlan)
        config.servers.map do |role, server|
          RolePlan.new(
            name: role,
            hosts: server.hosts,
            image: server.image || config.image,
            managed: server.managed?,
            cmd: server.cmd,
            units: server.units,
            proxy: server.proxy,
          )
        end
      end

      private def self.build_secrets(config : Config::DeployConfig) : Array(String)
        names = (config.env.try(&.secret) || [] of String).dup
        names.uniq!
        names.sort!
        names
      end

      private def self.build_hooks(config : Config::DeployConfig) : HooksPlan
        hooks = config.hooks
        return HooksPlan.new(nil, nil, [] of {String, Array(String)}) unless hooks

        remote_phases = [] of {String, Array(String)}
        if remote = hooks.remote
          {
            "before_transfer" => remote.before_transfer,
            "after_transfer"  => remote.after_transfer,
            "after_upload"    => remote.after_upload,
            "before_start"    => remote.before_start,
            "after_start"     => remote.after_start,
            "before_switch"   => remote.before_switch,
            "after_switch"    => remote.after_switch,
            "after_deploy"    => remote.after_deploy,
          }.each do |phase, entries|
            next if entries.empty?
            remote_phases << {phase, entries.map(&.command)}
          end
        end

        HooksPlan.new(
          pre_deploy: hooks.pre_deploy,
          post_deploy: hooks.post_deploy,
          remote: remote_phases,
        )
      end

      private def self.build_files(config : Config::DeployConfig) : Array(FilePlan)
        config.files.map do |entry|
          FilePlan.new(
            source: entry.source,
            destination: entry.destination,
            template: entry.template?,
            roles: entry.roles,
          )
        end
      end

      private def self.build_assets(config : Config::DeployConfig) : AssetsPlan?
        assets = config.assets
        return unless assets

        AssetsPlan.new(
          host: assets.host,
          command: assets.command,
          output_dir: assets.output_dir,
          retain_releases: assets.retain_releases,
        )
      end

      private def self.build_accessories(config : Config::DeployConfig) : Array(AccessoryPlan)
        accessories = config.accessories
        return [] of AccessoryPlan unless accessories

        accessories.map do |name, accessory|
          AccessoryPlan.new(
            name: name,
            image: accessory.image,
            host: accessory.host,
            port: accessory.port,
            volumes: accessory.volumes,
            secrets: accessory.env.try(&.secret) || [] of String,
            depends_on: accessory.depends_on,
          )
        end
      end
    end
  end
end
