PROJECT = MAIChat.xcodeproj
SCHEME = MAIChat
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
DERIVED_DATA ?= build/DerivedData

.PHONY: all build fmt clean

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

fmt:
	xcrun swift-format format -i -r MAIChat Shared MAIChatLiveActivityExtension

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED_DATA) clean
