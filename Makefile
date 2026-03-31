APP := meridian
ENTRYPOINT := src/meridian_cli.cr

.PHONY: build test lint release

build:
	crystal build $(ENTRYPOINT) -o bin/$(APP)

test:
	crystal spec

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
