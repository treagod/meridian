APP := meridian
ENTRYPOINT := src/meridian.cr

.PHONY: build test lint release

build:
	crystal build $(ENTRYPOINT) -o bin/$(APP)

test:
	crystal spec

lint:
	crystal tool format --check src spec

release:
	crystal build $(ENTRYPOINT) --release -o bin/$(APP)
