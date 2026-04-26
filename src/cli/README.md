# CLI dispatch layer

Each CLI command is a small class under `src/cli/commands/` that extends `CLI::Command`. The `REGISTRY` in `src/meridian.cr` lists every command class; `CLI.run` resolves the args to a class via longest-prefix match on the command's `name` and dispatches to its `invoke`.

The base class owns the parts that every command shares: OptionParser construction, `--help` detection, the `invalid_option` / `missing_option` / `unknown_args` wiring, the `--` separator split (for `exec`/`run`), and a uniform exception rescue. Subclasses declare only the command's identity, flags, and what to do with the parsed values.

## Adding a new command

Three steps:

1. Create one file under `src/cli/commands/<name>.cr`.
2. Add the class to the `REGISTRY` array in `src/meridian.cr`.
3. Done — `--help` for the command is auto-generated from `usage`, `description`, and the flags registered in `configure`.

### Worked example: `meridian prune`

A hypothetical command that removes stale images from each web host.

**`src/cli/commands/prune.cr`:**

```crystal
module Meridian
  module CLI
    module Commands
      class Prune < Command
        @file = "deploy.yml"
        @keep = 3

        def name : String
          "prune"
        end

        def summary : String
          "Remove old container images from web hosts"
        end

        def usage : String
          "Usage: meridian prune [options]"
        end

        def description : String
          "Remove stale container images from each configured web host."
        end

        def configure(parser : OptionParser) : Nil
          parser.on("--file PATH", "Path to deploy config (default: deploy.yml)") { |v| @file = v }
          parser.on("--keep N", "Number of recent images to retain (default: 3)") { |v| @keep = v.to_i }
        end

        # Optional — only override when the command can raise something the default doesn't cover.
        def rescuable : Array(Exception.class)
          super + [SSH::ConnectionError.as(Exception.class)]
        end

        def failure_message : String
          "Prune failed"
        end

        def call(ctx : Context, positionals : Array(String), remote_command : Array(String)) : Int32
          config = Config::Loader.load(@file)
          ::Meridian::Commands::Prune.new(
            config,
            ssh_executor: ctx.ssh_executor,
            output: ctx.output,
            error: ctx.error,
          ).run(keep: @keep)
          0
        end
      end
    end
  end
end
```

**`src/meridian.cr`** — add the class to `REGISTRY`:

```crystal
REGISTRY = Registry.new([
  Commands::Init,
  Commands::Deploy,
  # ...
  Commands::Prune,    # ← here
  # ...
] of Command.class)
```

That's it. `meridian --help` will list `prune` alongside the rest, and `meridian prune --help` renders Usage + description + flags from the command's own metadata.

## Variants

### A positional argument before the flags

Override `parse_positionals` to peel one or more leading args before OptionParser sees them. See `src/cli/commands/exec.cr` and `src/cli/commands/accessory.cr`.

```crystal
def parse_positionals(args : Array(String)) : {Array(String), Array(String)}
  first = args.first?
  if first.nil? || first.starts_with?('-')
    {[] of String, args}
  else
    {[first], args.size > 1 ? args[1..] : [] of String}
  end
end

def call(ctx, positionals, remote_command)
  if positionals.empty?
    ctx.error.puts "Missing required name"
    return 1
  end
  # ... use positionals.first
end
```

### A `--` separator (for passthrough commands)

Override `stop_at_separator?` to return `true`. Anything after `--` lands in the `remote_command` parameter of `call`. See `src/cli/commands/exec.cr` and `run.cr`.

```crystal
def stop_at_separator? : Bool
  true
end

def call(ctx, positionals, remote_command)
  # remote_command is everything after `--`
end
```

### A subcommand group (`meridian foo bar`)

A group is two parts: the **leaf** command (`name = "foo bar"`) and the **group** parent (`name = "foo"`).

The leaf is a normal `Command`. The group extends `GroupCommand` and lists its subcommands for help rendering. The registry's longest-prefix match routes `["foo", "bar", ...]` to the leaf and `["foo"]` (or `["foo", "unknown"]`) to the group, which prints help or `Missing/Unknown foo subcommand`.

```crystal
class Foo < GroupCommand
  def name : String;     "foo"; end
  def summary : String;  "Manage foos"; end
  def usage : String;    "Usage: meridian foo SUBCOMMAND [options]"; end

  def subcommand_summaries : Array({String, String})
    [
      {"bar", "Do the bar thing"},
    ]
  end
end

class FooBar < Command
  def name : String;        "foo bar"; end
  # ... rest is a normal command
end
```

Register both in `REGISTRY`. See `src/cli/commands/server.cr`, `accessory.cr`, `secret.cr`, `proxy.cr` for working examples.

## What the base class gives you for free

- `--help` / `-h` detection (including `stop_at_separator?` for passthrough commands)
- OptionParser with consistent error messages for invalid options, missing values, and unknown args
- `ParseError` rescue → prints to `ctx.error` and exits 1
- Exception rescue for everything in `rescuable` → prints `ex.message || failure_message` and exits 1
- Help output rendered from `usage`, `description`, and the flags registered in `configure`

The defaults for `rescuable` cover `Config::ValidationError`, `Config::UnknownRole`, `YAML::ParseException`, `File::NotFoundError`. Append command-specific exceptions with `super + [MyError.as(Exception.class)]`. Override entirely (no `super`) only when the default set doesn't apply — see `src/cli/commands/init.cr`.
