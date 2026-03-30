require "spec"
require "../src/meridian"

record CLIResult, output : String, exit_code : Int32

def run_cli(args : Array(String)) : CLIResult
  io = IO::Memory.new
  exit_code = Meridian::CLI.run(args, output: io, error: io)
  CLIResult.new(output: io.to_s, exit_code: exit_code)
end
