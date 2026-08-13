PROJECT = PocketMai.xcodeproj
SCHEME = PocketMai
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
DERIVED_DATA ?= build/DerivedData
DEVICE ?=
BUNDLE_ID = io.github.trufae.mai
APP_BUNDLE ?=
XCODE_DERIVED_DATA ?= $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: all build run fmt clean check-shared-tooling aitest-build

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

# Installs and foreground-launches the latest signed Xcode device build on the
# first connected iOS device. Pass DEVICE=<UDID> or APP_BUNDLE=<path> to
# choose a device or app bundle.
run:
	@set -e; \
	device='$(DEVICE)'; \
	app_bundle='$(APP_BUNDLE)'; \
	if [ -z "$$device" ]; then \
		devices_json="$$(mktemp -t pocketmai-devices.XXXXXX)"; \
		trap 'rm -f "$$devices_json"' EXIT; \
		xcrun devicectl list devices --json-output "$$devices_json" >/dev/null; \
		device="$$(jq -r '.result.devices[] | select(.hardwareProperties.platform == "iOS") | .identifier' "$$devices_json" | head -n 1)"; \
	fi; \
	if [ -z "$$device" ] || [ "$$device" = "null" ]; then \
		echo "No connected iOS device found. Pass DEVICE=<UDID> to select one." >&2; \
		exit 1; \
	fi; \
	if [ -z "$$app_bundle" ]; then \
		for candidate in "$(XCODE_DERIVED_DATA)"/$(SCHEME)-*/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app; do \
			[ -d "$$candidate" ] || continue; \
			if [ -z "$$app_bundle" ] || [ "$$candidate" -nt "$$app_bundle" ]; then app_bundle="$$candidate"; fi; \
		done; \
	fi; \
	if [ -z "$$app_bundle" ] || [ ! -d "$$app_bundle" ]; then \
		echo "No signed $(CONFIG) device build found. Build the app in Xcode first, or pass APP_BUNDLE=<path>." >&2; \
		exit 1; \
	fi; \
	xcrun devicectl device install app --device "$$device" "$$app_bundle"; \
	xcrun devicectl device process launch --terminate-existing --device "$$device" "$(BUNDLE_ID)"

fmt:
	xcrun swift-format format -i -r PocketMai Shared PocketMaiLiveActivityExtension

check-shared-tooling:
	test "$$(readlink aitest/Sources/aitest/AgentTooling.swift)" = "../../../Shared/AgentTooling.swift"

aitest-build: check-shared-tooling
	swift build --package-path aitest

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED_DATA) clean
