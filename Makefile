PROJECT = PocketMai.xcodeproj
SCHEME = PocketMai
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
DERIVED_DATA ?= build/DerivedData
DEVICE ?=
BUNDLE_ID = io.github.trufae.mai
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app

.PHONY: all build run fmt clean check-shared-tooling aitest-build

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

# Builds, installs, and foreground-launches on the first connected iOS device.
# Pass DEVICE=<UDID> to choose a particular device.
run:
	@set -e; \
	device='$(DEVICE)'; \
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
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination "platform=iOS,id=$$device" -derivedDataPath $(DERIVED_DATA) -allowProvisioningUpdates build; \
	xcrun devicectl device install app --device "$$device" "$(APP_BUNDLE)"; \
	xcrun devicectl device process launch --terminate-existing --device "$$device" "$(BUNDLE_ID)"

fmt:
	xcrun swift-format format -i -r PocketMai Shared PocketMaiLiveActivityExtension

check-shared-tooling:
	test "$$(readlink aitest/Sources/aitest/AgentTooling.swift)" = "../../../Shared/AgentTooling.swift"

aitest-build: check-shared-tooling
	swift build --package-path aitest

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED_DATA) clean
