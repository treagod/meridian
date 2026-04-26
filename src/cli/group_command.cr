module Meridian
  module CLI
    abstract class GroupCommand < Command
      abstract def subcommand_summaries : Array({String, String})

      def description : String
        ""
      end

      def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
        1
      end

      def invoke(ctx : Context, args : Array(String)) : Int32
        if args.first?.try(&.in?(HELP_FLAGS))
          return print_help(ctx.output)
        end

        if args.empty?
          ctx.error.puts "Missing #{name} subcommand"
          return 1
        end

        ctx.error.puts "Unknown #{name} subcommand: #{args.first}"
        1
      end

      def print_help(io : IO) : Int32
        io.puts usage
        io.puts
        io.puts "#{name.capitalize} subcommands:"
        subcommand_summaries.each do |(token, summary)|
          io.puts "    #{token.ljust(26)} #{summary}"
        end
        io.puts
        io.puts "Run `meridian #{name} SUBCOMMAND --help` for subcommand options."
        0
      end
    end
  end
end
