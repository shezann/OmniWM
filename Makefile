.PHONY: format format-check lint lint-fix build run energy-profile test-skylight-live release-check verify check check-tool-versions check-swiftformat-version check-swiftlint-version

SWIFTFORMAT_VERSION = 0.63.0
SWIFTLINT_VERSION = 0.65.1
SWIFT_WITH_GHOSTTY = LIBRARY_PATH="$$(./Scripts/ghostty-preflight.sh print-library-dir)$${LIBRARY_PATH:+:$$LIBRARY_PATH}"

check-swiftformat-version:
	@actual="$$(swiftformat --version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTFORMAT_VERSION)" ]; then echo "error: SwiftFormat $(SWIFTFORMAT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-swiftlint-version:
	@actual="$$(swiftlint version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTLINT_VERSION)" ]; then echo "error: SwiftLint $(SWIFTLINT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-tool-versions: check-swiftformat-version check-swiftlint-version

format: check-swiftformat-version
	swiftformat .

format-check: check-swiftformat-version
	swiftformat --lint .

lint: check-swiftlint-version
	swiftlint lint

lint-fix: check-tool-versions
	swiftformat .
	swiftlint lint --fix || true
	swiftformat .
	swiftlint lint

build:
	./Scripts/ghostty-preflight.sh verify
	$(SWIFT_WITH_GHOSTTY) swift build --arch arm64

run:
	./Scripts/package-app.sh debug dev
	@# Wait for the old instance to exit before relaunching; calling `open`
	@# while the previous process is still tearing down makes LaunchServices
	@# fail with error -600 (procNotFound).
	@if pgrep -x OmniWM >/dev/null; then \
		pkill -x OmniWM; \
		for _ in $$(seq 1 50); do pgrep -x OmniWM >/dev/null || break; sleep 0.2; done; \
		if pgrep -x OmniWM >/dev/null; then echo "OmniWM did not exit; forcing"; pkill -9 -x OmniWM; sleep 0.5; fi; \
	fi
	open ./dist/OmniWM.app

energy-profile:
	./Scripts/energy-profile.sh

test-skylight-live:
	OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 swift test --filter SkyLightNativeSpaceInventoryLiveTests/testLiveTransactionMoveIsObservedThroughWindowServerBounds

release-check: build

verify: format-check lint build

check: verify
