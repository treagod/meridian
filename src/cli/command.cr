module Meridian
  module CLI
    abstract class Command
      HELP_FLAGS = ["-h", "--help"]

      class ParseError < Exception
      end

      abstract def name : String
      abstract def summary : String
      abstract def usage : String
      abstract def description : String
      abstract def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32

      def configure(parser : OptionParser) : Nil
      end

      def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
        {[] of String, args}
      end

      def stop_at_separator? : Bool
        false
      end

      def rescuable : Array(Exception.class)
        [
          Config::ValidationError,
          Config::UnknownRole,
          YAML::ParseException,
          File::NotFoundError,
        ] of Exception.class
      end

      def failure_message : String
        "#{name} failed"
      end

      def invoke(ctx : Context, args : Array(String)) : Int32
        option_args, remote_command =
          if stop_at_separator?
            split_at_separator(args)
          else
            {args, [] of String}
          end

        return print_help(ctx.output) if option_args.any?(&.in?(HELP_FLAGS))

        positionals, parser_args = parse_positionals(option_args)

        parser = build_parser
        parser.parse(parser_args.dup)

        call(ctx, positionals, remote_command)
      rescue ex : ParseError
        ctx.error.puts ex.message || "Invalid #{name} arguments"
        1
      rescue ex : Exception
        raise ex unless rescuable.any? { |klass| ex.class <= klass }
        ctx.error.puts ex.message || failure_message
        1
      end

      def print_help(io : IO) : Int32
        io.puts build_parser.to_s
        0
      end

      protected def build_parser : OptionParser
        parser = OptionParser.new
        parser.banner = build_banner
        configure(parser)
        parser.on("-h", "--help", "Show this help") { }
        parser.invalid_option { |flag| raise ParseError.new("Invalid option: #{flag}") }
        parser.missing_option { |flag| raise ParseError.new("Missing option value: #{flag}") }
        parser.unknown_args do |before_dash, after_dash|
          unknown = before_dash + after_dash
          raise ParseError.new("Unknown arguments: #{unknown.join(" ")}") unless unknown.empty?
        end
        parser
      end

      protected def build_banner : String
        String.build do |io|
          io.puts usage
          io.puts
          description.each_line { |line| io.puts line }
          io.puts
          io.puts "Options:"
        end.chomp
      end

      protected def split_at_separator(args : Array(String)) : {Array(String), Array(String)}
        separator_index = args.index("--")
        return {args, [] of String} unless separator_index

        option_args = args[0...separator_index]
        remote_command =
          if separator_index == args.size - 1
            [] of String
          else
            args[(separator_index + 1)..]
          end

        {option_args, remote_command}
      end
    end
  end
end
