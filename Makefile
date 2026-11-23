.PHONY: app check-clt-build test format format-check

SWIFT ?= swift
TEST_FLAGS := -c release -Xswiftc -enable-testing
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
	$(SWIFT) test $(TEST_FLAGS)
	AGENT_USAGE_MEMORY_REGRESSION=1 $(SWIFT) test $(TEST_FLAGS) --skip-build --filter PiHistoryMemoryTests

format:
	$(SWIFT) format format --configuration .swift-format --in-place --recursive $(SWIFT_FILES)

format-check:
	$(SWIFT) format lint --configuration .swift-format --strict --recursive $(SWIFT_FILES)
