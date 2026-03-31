# Ameba Issues

Captured from `bin/ameba` on 2026-03-31.

Summary:
- 35 files inspected
- 27 failures

Breakdown by file:
- `spec/config/loader_spec.cr`: 14 issues
  - `Lint/NotNil` at lines 32, 37, 42, 47, 52, 72, 77, 82, 101, 120, 135
  - `Style/HeredocIndent` at lines 86, 105, 124
- `spec/deploy/orchestrator_spec.cr`: 3 issues
  - `Lint/NotNil` at lines 69, 72, 73
- `spec/meridian_spec.cr`: 2 issues
  - `Lint/NotNil` at lines 52, 63
- `spec/proxy/manager_spec.cr`: 2 issues
  - `Performance/ChainedCallWithNoBang` at line 60 (`uniq!`, `sort!`)
- `spec/quadlet/generator_spec.cr`: 1 issue
  - `Style/HeredocIndent` at line 98
- `spec/spec_helper.cr`: 2 issues
  - `Style/HeredocIndent` at lines 120, 143
- `src/config/loader.cr`: 2 issues
  - `Style/RedundantNilInControlExpression` at lines 128, 129
- `src/health/checker.cr`: 1 issue
  - `Lint/RequireParentheses` at line 59

Raw `ameba` output:

```text
Inspecting 35 files

spec/config/loader_spec.cr:32:20
[W] Lint/NotNil: Avoid using `not_nil!`
> config.proxy.not_nil!.image.should eq("ghcr.io/basecamp/kamal-proxy:latest")

spec/config/loader_spec.cr:37:35
[W] Lint/NotNil: Avoid using `not_nil!`
> config.servers["web"].proxy.not_nil!.host.should eq("myapp.example.com")

spec/config/loader_spec.cr:42:23
[W] Lint/NotNil: Avoid using `not_nil!`
> config.registry.not_nil!.server.should eq("registry.example.com")

spec/config/loader_spec.cr:47:18
[W] Lint/NotNil: Avoid using `not_nil!`
> config.env.not_nil!.clear["RAILS_ENV"].should eq("production")

spec/config/loader_spec.cr:52:18
[W] Lint/NotNil: Avoid using `not_nil!`
> config.env.not_nil!.secret.should contain("SECRET_KEY_BASE")

spec/config/loader_spec.cr:72:35
[W] Lint/NotNil: Avoid using `not_nil!`
> config.servers["web"].proxy.not_nil!.healthcheck.path.should eq("/health")

spec/config/loader_spec.cr:77:26
[W] Lint/NotNil: Avoid using `not_nil!`
> config.accessories.not_nil!["db"].image.should eq("docker.io/library/postgres:16")

spec/config/loader_spec.cr:82:26
[W] Lint/NotNil: Avoid using `not_nil!`
> config.accessories.not_nil!["db"].host.should eq("192.168.1.20")

spec/config/loader_spec.cr:86:14 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> yaml = <<-YAML

spec/config/loader_spec.cr:101:18
[W] Lint/NotNil: Avoid using `not_nil!`
> ex.message.not_nil!.should contain("service")

spec/config/loader_spec.cr:105:14 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> yaml = <<-YAML

spec/config/loader_spec.cr:120:18
[W] Lint/NotNil: Avoid using `not_nil!`
> ex.message.not_nil!.should contain("image")

spec/config/loader_spec.cr:124:14 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> yaml = <<-YAML

spec/config/loader_spec.cr:135:18
[W] Lint/NotNil: Avoid using `not_nil!`
> ex.message.not_nil!.should contain("servers")

spec/deploy/orchestrator_spec.cr:69:28
[W] Lint/NotNil: Avoid using `not_nil!`
> network_upload.input.not_nil!.should contain("[Network]")

spec/deploy/orchestrator_spec.cr:72:30
[W] Lint/NotNil: Avoid using `not_nil!`
> container_upload.input.not_nil!.should contain("[Container]")

spec/deploy/orchestrator_spec.cr:73:30
[W] Lint/NotNil: Avoid using `not_nil!`
> container_upload.input.not_nil!.should contain("ContainerName=myapp-green")

spec/meridian_spec.cr:52:27
[W] Lint/NotNil: Avoid using `not_nil!`
> fake_orchestrator.not_nil!.as(Meridian::Deploy::Orchestrator)

spec/meridian_spec.cr:63:27
[W] Lint/NotNil: Avoid using `not_nil!`
> fake_orchestrator.not_nil!.deploy_calls.should eq(1)

spec/proxy/manager_spec.cr:60:60 [Correctable]
[W] Performance/ChainedCallWithNoBang: Use bang method variant `uniq!` after chained `map` call
> touched_hosts = runner.invocations.map(&.args.first).uniq.sort

spec/proxy/manager_spec.cr:60:65 [Correctable]
[W] Performance/ChainedCallWithNoBang: Use bang method variant `sort!` after chained `uniq` call
> touched_hosts = runner.invocations.map(&.args.first).uniq.sort

spec/quadlet/generator_spec.cr:98:28 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> config = load_config(<<-YAML)

spec/spec_helper.cr:120:18 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> MINIMAL_CONFIG = <<-YAML

spec/spec_helper.cr:143:15 [Correctable]
[C] Style/HeredocIndent: Heredoc body should be indented by 2 spaces
> FULL_CONFIG = <<-YAML

src/config/loader.cr:128:16 [Correctable]
[C] Style/RedundantNilInControlExpression: Redundant `nil` detected
> return nil unless node.is_a?(YAML::Nodes::Scalar)

src/config/loader.cr:129:16 [Correctable]
[C] Style/RedundantNilInControlExpression: Redundant `nil` detected
> return nil if node.value.empty?

src/health/checker.cr:59:9
[W] Lint/RequireParentheses: Use parentheses in the method call to avoid confusion about precedence
> raise last_error || CheckFailed.new("Health check failed for #{url}")

Finished in 162.02 milliseconds
35 inspected, 27 failures
```

Note:
- There is an in-progress local patch addressing part of this list in the current worktree.
