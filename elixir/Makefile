.PHONY: help all setup deps fmt fmt-check lint test

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, all"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

test:
	$(MIX) test

all: deps fmt-check lint test
