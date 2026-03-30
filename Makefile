APP := meridian
ENTRYPOINT := src/meridian_cli.cr

.PHONY: build test lint release

build:
	crystal build $(ENTRYPOINT) -o bin/$(APP)

test:
	crystal spec

lint:
	crystal tool format --check src spec
	bin/ameba

release:
	crystal build $(ENTRYPOINT) --release -o bin/$(APP)
