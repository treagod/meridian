module Meridian
  module CLI
    module Commands
      class Init < Command
        @force = false

        def name : String
          "init"
        end

        def summary : String
          "Generate the .meridian/ project layout"
        end

        def usage : String
          "Usage: meridian init [options]"
        end

        def description : String
          "Generate .meridian/deploy.yml and supporting files for the current project directory."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--force", "Overwrite an existing .meridian/deploy.yml") { @force = true }
        end

        def rescuable : Array(Exception.class)
          [::Meridian::Init::Error, File::Error] of Exception.class
        end

        def failure_message : String
          "Init failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          ::Meridian::Init::Service.new(root: Dir.current, input: ctx.input, output: ctx.output).run(force: @force)
          0
        end
      end
    end
  end
end
