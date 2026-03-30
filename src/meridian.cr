require "option_parser"
require "./errors"
require "./commands/**"
require "./config/loader"
require "./deploy/orchestrator"
require "./health/checker"
require "./proxy/manager"
require "./quadlet/generator"
require "./ssh/executor"
require "./transfer/incremental"
require "./transfer/stream"

module Meridian
  VERSION = "0.1.0"

  module CLI
    COMMANDS = {
      "deploy",
      "setup",
      "rollback",
      "status",
      "logs",
      "exec",
    }

    def self.run(args : Array(String), *, output : IO = STDOUT, error : IO = STDERR) : Int32
      return print_help(output) if args.empty?

      parser = build_parser(error)
      remaining_args = args.dup
      command = nil
      exit_code = 0
      handled = false

      parser.on("-h", "--help", "Show this help") do
        exit_code = print_help(output)
        handled = true
        parser.stop
      end

      parser.on("-v", "--version", "Show the version") do
        output.puts VERSION
        exit_code = 0
        handled = true
        parser.stop
      end

      parser.unknown_args do |before_dash, _after_dash|
        command = before_dash.first? unless handled
      end

      parser.invalid_option do |flag|
        error.puts "Invalid option: #{flag}"
        exit_code = 1
        handled = true
        parser.stop
      end

      parser.parse(remaining_args)

      return exit_code if handled
      return dispatch(command.not_nil!, output, error) if command

      print_help(output)
    end

    private def self.build_parser(error : IO) : OptionParser
      OptionParser.new.tap do |parser|
        parser.banner = "Usage: meridian [command] [options]"

        parser.missing_option do |flag|
          error.puts "Missing option value: #{flag}"
          parser.stop
        end
      end
    end

    private def self.dispatch(command : String, output : IO, error : IO) : Int32
      if COMMANDS.includes?(command)
        output.puts "Not yet implemented"
        0
      else
        error.puts "Unknown command: #{command}"
        1
      end
    end

    private def self.print_help(io : IO) : Int32
      io.puts "Usage: meridian [command] [options]"
      io.puts
      io.puts "Commands:"
      COMMANDS.each do |command|
        io.puts "    #{command}"
      end
      io.puts
      io.puts "Options:"
      io.puts "    -h, --help                 Show this help"
      io.puts "    -v, --version              Show the version"
      0
    end
  end
end
