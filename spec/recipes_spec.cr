require "./spec_helper"

private def recipe_deploy_configs(content : String) : Array(String)
  configs = [] of String
  awaiting_yaml = false
  collecting = false
  lines = [] of String

  content.each_line(chomp: true) do |line|
    if collecting
      if line == "```"
        configs << lines.join('\n')
        lines.clear
        collecting = false
      else
        lines << line
      end
    elsif line.starts_with?("## ")
      awaiting_yaml = line.includes?("deploy.yml")
    elsif awaiting_yaml && line == "```yaml"
      awaiting_yaml = false
      collecting = true
    end
  end

  configs
end

describe "documentation recipes" do
  Dir.glob("docs/recipes/*.md").sort.each do |path|
    next if path.ends_with?("/index.md")

    it "loads and generates Quadlets for every deploy.yml in #{path}" do
      configs = recipe_deploy_configs(File.read(path))
      configs.should_not be_empty

      configs.each do |yaml|
        config = Meridian::Config::Loader.parse(yaml)
        generator = Meridian::Quadlet::Generator.new(config)

        generator.network_file.should_not be_empty
        config.servers.each do |role, server|
          next unless server.managed?

          if server.proxy
            generator.container_file(server, Meridian::Quadlet::Color::Blue).should_not be_empty
          else
            generator.role_container_file(role, server).should_not be_empty
          end
        end
        if config.servers.values.any?(&.proxy)
          generator.proxy_network_file.should_not be_empty
          generator.proxy_container_file.should_not be_empty
        end
        config.accessories.try do |accessories|
          accessories.each do |name, accessory|
            generator.accessory_container_file(name, accessory).should_not be_empty
          end
        end
        if config.assets
          generator.assets_volume_file.should_not be_empty
          generator.assets_builder_file("test-release").should_not be_empty
          generator.assets_server_file.should_not be_empty
          generator.assets_caddy_config.should_not be_empty
        end
      end
    end
  end
end
