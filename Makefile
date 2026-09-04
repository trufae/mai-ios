PROJECT = PocketMai.xcodeproj
SCHEME = PocketMai
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?=
DERIVED_DATA ?= build/DerivedData
XCODE_PACKAGE_FLAGS ?= -skipPackagePluginValidation
DEVICE ?=
BUNDLE_ID = io.github.trufae.mai
APP_BUNDLE ?=

.PHONY: all build test list run repl fmt clean check-shared-tooling aitest-build

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) $(XCODE_PACKAGE_FLAGS) CODE_SIGNING_ALLOWED=NO build

test:
	@set -e; \
	destination='$(TEST_DESTINATION)'; \
	if [ -z "$$destination" ]; then \
		simulator_id="$$(xcrun simctl list devices available --json | jq -r '[.devices | to_entries[] | select(.key | contains("SimRuntime.iOS-")) | . as $$runtime | .value[] | select(.isAvailable == true and (.name | startswith("iPhone"))) | {runtime: ($$runtime.key | split("iOS-")[1] | split("-") | map(tonumber)), udid: .udid}] | sort_by(.runtime) | last | .udid // empty')"; \
		if [ -z "$$simulator_id" ]; then \
			echo "No available iPhone simulator found" >&2; \
			exit 1; \
		fi; \
		xcrun simctl boot "$$simulator_id" 2>/dev/null || true; \
		xcrun simctl bootstatus "$$simulator_id" -b; \
		destination="platform=iOS Simulator,id=$$simulator_id"; \
	fi; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination "$$destination" -derivedDataPath $(DERIVED_DATA) $(XCODE_PACKAGE_FLAGS) CODE_SIGNING_ALLOWED=NO test

list:
	xcrun devicectl list devices

# Builds, installs, and foreground-launches the app on the first connected iOS
# device. Pass DEVICE=<UDID> to choose a device, or APP_BUNDLE=<path> to skip
# the build and install a specific prebuilt app bundle.
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
		xcodebuild -project '$(PROJECT)' -scheme '$(SCHEME)' -configuration '$(CONFIG)' \
			-destination "platform=iOS,id=$$device" -derivedDataPath '$(DERIVED_DATA)' \
			$(XCODE_PACKAGE_FLAGS) -allowProvisioningUpdates build; \
		app_bundle='$(DERIVED_DATA)/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app'; \
	fi; \
	if [ -z "$$app_bundle" ] || [ ! -d "$$app_bundle" ]; then \
		echo "No signed $(CONFIG) device build found at $$app_bundle." >&2; \
		exit 1; \
	fi; \
	xcrun devicectl device install app --device "$$device" "$$app_bundle"; \
	xcrun devicectl device process launch --terminate-existing --device "$$device" "$(BUNDLE_ID)"

repl:
	swift run --package-path MaiCore mai $(ARGS)

fmt:
	xcrun swift-format format -i -r PocketMai Shared PocketMaiLiveActivityExtension MaiCore/Sources MaiCore/Tests MaiCore/Package.swift

check-shared-tooling:
	test "$$(readlink aitest/Sources/aitest/AgentTooling.swift)" = "../../../Shared/AgentTooling.swift"

aitest-build: check-shared-tooling
	swift build --package-path aitest

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED_DATA) clean
