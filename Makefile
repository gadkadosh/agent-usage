.PHONY: app format format-check

SWIFT ?= swift
SWIFT_FILES := Package.swift Sources Tests

app:
	SWIFT="$(SWIFT)" /bin/bash scripts/build-app.sh

format:
	$(SWIFT) format format --configuration .swift-format --in-place --recursive $(SWIFT_FILES)

format-check:
	$(SWIFT) format lint --configuration .swift-format --strict --recursive $(SWIFT_FILES)
