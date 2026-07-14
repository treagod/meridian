APP := meridian
ENTRYPOINT := src/meridian_cli.cr

.PHONY: build test lint release e2e-marten e2e-marten-postgres e2e-rails-postgres e2e-all

build:
	crystal build $(ENTRYPOINT) -o bin/$(APP)

test:
	crystal spec

e2e-marten:
	./scripts/test-recipe marten-sqlite-assets

e2e-marten-postgres:
	./scripts/test-recipe marten-postgres-dragonfly-assets

e2e-rails-postgres:
	./scripts/test-recipe rails-postgres

e2e-all: e2e-marten e2e-marten-postgres e2e-rails-postgres

.PHONY: format
## Perform and apply crystal formatting.
format:
	crystal tool format -e tmp

.PHONY: format_checks
## Trigger crystal formatting checks.
format_checks:
	crystal tool format --check -e tmp

.PHONY: lint
## Trigger code quality checks.
lint:
	bin/ameba.cr

release:
	crystal build $(ENTRYPOINT) --release -o bin/$(APP)
