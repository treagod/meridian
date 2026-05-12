module Meridian
  module Commands
    class Plan
      LABEL_WIDTH = 11

      @config : Config::DeployConfig
      @output : IO

      def initialize(@config : Config::DeployConfig, @output : IO = STDOUT)
      end

      def run : Nil
        plan = Deploy::Plan.from(@config)

        write_header(plan)
        @output.puts
        write_roles(plan)
        @output.puts
        write_env(plan)
        @output.puts
        write_files(plan)
        write_hooks(plan)
        write_assets(plan)
        write_accessories(plan)
      end

      private def write_header(plan : Deploy::Plan) : Nil
        write_field("service", plan.service)
        write_field("image", plan.default_image)
        write_field("transfer", plan.transfer_mode.try(&.to_s.downcase) || "registry")
        write_field("ssh user", plan.ssh_user)
        write_field("boot", "limit=#{plan.boot.limit} wait=#{plan.boot.wait}")
        if registry = plan.registry
          if server = registry.server
            write_field("registry", server)
          end
        end
      end

      private def write_roles(plan : Deploy::Plan) : Nil
        @output.puts "roles:"
        plan.roles.each do |role|
          marker = role.managed ? "managed" : "unmanaged"
          @output.puts "  #{role.name} (#{marker})  image=#{role.image}"
          @output.puts "    hosts:    #{role.hosts.empty? ? "(none)" : role.hosts.join(", ")}"
          if cmd = role.cmd
            @output.puts "    cmd:      #{cmd}"
          end
          unless role.units.empty?
            @output.puts "    units:    #{role.units.join(", ")}"
          end
          if proxy = role.proxy
            @output.puts "    proxy:    #{format_proxy(proxy)}"
          end
        end
      end

      private def format_proxy(proxy : Config::ServerProxyConfig) : String
        parts = [] of String
        parts << "host=#{proxy.host || "-"}"
        parts << "ssl=#{proxy.ssl?}"
        parts << "app_port=#{proxy.app_port}"
        parts << "health=#{proxy.healthcheck.path}"
        if path = proxy.path
          parts << "path=#{path}"
        end
        parts.join(" ")
      end

      private def write_env(plan : Deploy::Plan) : Nil
        @output.puts "env:"
        clear = plan.clear_env
        if clear.empty?
          @output.puts "  clear:    (none)"
        else
          rendered = clear.map { |key, value| "#{key}=#{value}" }.join(", ")
          @output.puts "  clear:    #{rendered}"
        end
        secrets = plan.secrets.empty? ? "(none)" : plan.secrets.join(", ")
        @output.puts "  secrets:  #{secrets}"
      end

      private def write_files(plan : Deploy::Plan) : Nil
        if plan.files.empty?
          @output.puts "files: (none)"
          return
        end

        @output.puts "files:"
        plan.files.each do |file|
          suffix = file.template ? " (template)" : ""
          roles = file.roles.try { |entries| " roles=#{entries.join(",")}" } || ""
          @output.puts "  #{file.source} -> #{file.destination}#{suffix}#{roles}"
        end
      end

      private def write_hooks(plan : Deploy::Plan) : Nil
        if plan.hooks.empty?
          @output.puts "hooks: (none)"
          return
        end

        @output.puts "hooks:"
        if pre = plan.hooks.pre_deploy
          @output.puts "  pre_deploy:  #{pre}"
        end
        if post = plan.hooks.post_deploy
          @output.puts "  post_deploy: #{post}"
        end
        plan.hooks.remote.each do |(phase, commands)|
          @output.puts "  #{phase}:"
          commands.each { |cmd| @output.puts "    - #{cmd}" }
        end
      end

      private def write_assets(plan : Deploy::Plan) : Nil
        unless assets = plan.assets
          @output.puts "assets: (none)"
          return
        end

        @output.puts "assets:"
        @output.puts "  host:            #{assets.host}"
        @output.puts "  command:         #{assets.command}"
        @output.puts "  output_dir:      #{assets.output_dir}"
        @output.puts "  retain_releases: #{assets.retain_releases}"
      end

      private def write_accessories(plan : Deploy::Plan) : Nil
        if plan.accessories.empty?
          @output.puts "accessories: (none)"
          return
        end

        @output.puts "accessories:"
        plan.accessories.each do |accessory|
          parts = [] of String
          parts << "image=#{accessory.image || "-"}"
          parts << "host=#{accessory.host || "-"}"
          if port = accessory.port
            parts << "port=#{port}"
          end
          if depends_on = accessory.depends_on
            parts << "depends_on=#{depends_on}"
          end
          @output.puts "  #{accessory.name}  #{parts.join(" ")}"
          unless accessory.volumes.empty?
            @output.puts "    volumes:  #{accessory.volumes.join(", ")}"
          end
          unless accessory.secrets.empty?
            @output.puts "    secrets:  #{accessory.secrets.join(", ")}"
          end
        end
      end

      private def write_field(label : String, value : String) : Nil
        @output.puts "#{(label + ":").ljust(LABEL_WIDTH)}#{value}"
      end
    end
  end
end
