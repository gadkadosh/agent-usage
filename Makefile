.PHONY: app test format format-check

SWIFT ?= swift
SWIFT_FILES := Package.swift Sources Tests

app:
	SWIFT="$(SWIFT)" /bin/bash scripts/build-app.sh

test:
	$(SWIFT) test
	AGENT_USAGE_MEMORY_REGRESSION=1 $(SWIFT) test --skip-build --filter PiHistoryMemoryTests

format:
	$(SWIFT) format format --configuration .swift-format --in-place --recursive $(SWIFT_FILES)

format-check:
	$(SWIFT) format lint --configuration .swift-format --strict --recursive $(SWIFT_FILES)
