module Meridian
  module CLI
    module Commands
      class Quadlet < Command
        @color : ::Meridian::Quadlet::Color? = nil
        @output_dir = "./quadlet-preview"
        @file = "deploy.yml"

        def name : String
          "quadlet"
        end

        def summary : String
          "Generate Quadlet files locally"
        end

        def usage : String
          "Usage: meridian quadlet [options]"
        end

        def description : String
          "Generate Quadlet files locally for inspection."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--color COLOR", "Deployment color (blue or green)") do |value|
            @color = ::Meridian::Quadlet::Color.parse?(value) || raise ParseError.new("Invalid color: #{value}")
          end
          parser.on("--output-dir DIR", "Directory for generated Quadlet files") { |value| @output_dir = value }
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |value| @file = value }
        end

        def rescuable : Array(Exception.class)
          super + [ArgumentError.as(Exception.class)]
        end

        def failure_message : String
          "Failed to generate Quadlet preview"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          color = @color
          unless color
            ctx.error.puts "Missing required option: --color"
            return 1
          end

          config = Config::Loader.load(@file)
          generator = ::Meridian::Quadlet::Generator.new(config)
          generator.write_to_directory(@output_dir, color)
          ctx.output.puts "Wrote Quadlet preview to #{@output_dir}"
          0
        end
      end
    end
  end
end
