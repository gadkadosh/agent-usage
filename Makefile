.PHONY: app check-clt-build test format format-check

SWIFT ?= swift
SWIFT_FILES := Package.swift Sources Tests

app:
	SWIFT="$(SWIFT)" /bin/bash scripts/build-app.sh

check-clt-build:
	@set -eu; \
	scratch=$$(mktemp -d); \
	trap 'rm -rf "$$scratch"' EXIT; \
	DEVELOPER_DIR=/Library/Developer/CommandLineTools \
		xcrun swift build --configuration release --product AgentUsage --scratch-path "$$scratch"

test:
	$(SWIFT) test
	AGENT_USAGE_MEMORY_REGRESSION=1 $(SWIFT) test --skip-build --filter PiHistoryMemoryTests

format:
	$(SWIFT) format format --configuration .swift-format --in-place --recursive $(SWIFT_FILES)

format-check:
	$(SWIFT) format lint --configuration .swift-format --strict --recursive $(SWIFT_FILES)
