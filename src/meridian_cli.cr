require "./meridian"

exit Meridian::CLI.run(ARGV, output: STDOUT, error: STDERR)
