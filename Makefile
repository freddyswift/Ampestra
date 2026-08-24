CODESIGN_IDENTITY ?= -
VERSION ?=
SWIFT ?= ./script/swift.sh
SDK ?=
IOS_SCHEME ?= Ampestra iOS
IOS_ARCHIVE_PATH ?= dist/ios/Ampestra.xcarchive
IOS_EXPORT_PATH ?= dist/ios/upload
IOS_EXPORT_OPTIONS ?= iOS/ExportOptions-TestFlight.plist

ifeq ($(SDK),27)
export DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer
else ifneq ($(SDK),)
$(error SDK must be 27)
endif

-include .env.release

export SPARKLE_PUBLIC_ED_KEY
export NOTARY_PROFILE

.PHONY: build check version-check ios-project ios-build ios-test ios-archive ios-upload run dev-reset dev-reset-hard dev-fresh dev-fresh-hard release-build release release-upload release-test release-config sparkle-key notary-profile app install release-package clean

build:
	$(SWIFT) build

check:
	$(SWIFT) build -Xswiftc -warnings-as-errors
	$(SWIFT) test
	for f in script/*.sh; do bash -n "$$f"; done
	plutil -lint Sources/Ampestra/Info.plist
	plutil -lint iOS/AmpestraMobile/Info.plist
	plutil -lint $(IOS_EXPORT_OPTIONS)
	$(MAKE) version-check

version-check:
	./script/check_release_versions.sh

ios-project:
	xcodegen generate --spec project.yml

ios-build: ios-project
	xcodebuild -project Ampestra.xcodeproj -scheme "$(IOS_SCHEME)" -destination "generic/platform=iOS Simulator" build CODE_SIGNING_ALLOWED=NO

ios-test: ios-project
	xcodebuild -project Ampestra.xcodeproj -scheme "$(IOS_SCHEME)" -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0" test CODE_SIGNING_ALLOWED=NO

ios-archive: version-check ios-project
	mkdir -p "$(dir $(IOS_ARCHIVE_PATH))"
	xcodebuild -project Ampestra.xcodeproj -scheme "$(IOS_SCHEME)" -configuration Release -destination "generic/platform=iOS" -archivePath "$(IOS_ARCHIVE_PATH)" -allowProvisioningUpdates clean archive

ios-upload: ios-archive
	mkdir -p "$(IOS_EXPORT_PATH)"
	xcodebuild -exportArchive -archivePath "$(IOS_ARCHIVE_PATH)" -exportPath "$(IOS_EXPORT_PATH)" -exportOptionsPlist "$(IOS_EXPORT_OPTIONS)" -allowProvisioningUpdates

run:
	./script/build_and_run.sh

dev-reset:
	./script/reset_dev.sh

dev-reset-hard:
	./script/reset_dev.sh --include-production-permissions

dev-fresh: dev-reset
	./script/build_and_run.sh

dev-fresh-hard: dev-reset-hard
	./script/build_and_run.sh

release-build:
	$(SWIFT) build -c release

app:
	SPARKLE_PUBLIC_ED_KEY= SPARKLE_FEED_URL= CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" ./script/install_app.sh --stage-only

install:
	SPARKLE_PUBLIC_ED_KEY= SPARKLE_FEED_URL= ./script/install_app.sh

release:
	./script/release.sh $(VERSION)

release-upload:
	./script/release.sh $(VERSION) --upload

release-test:
	RELEASE_DIR=dist/test-releases SPARKLE_PUBLIC_ED_KEY=dry-run-public-key NOTARY_PROFILE= ./script/release.sh $(VERSION) --no-upload --no-appcast --no-git-check --yes

release-config:
	@printf "Sparkle public EdDSA key: "; read -r sparkle_key; \
	printf "Notary profile [Ampestra, '-' skips]: "; read -r notary_profile; \
	if [ -z "$$notary_profile" ]; then notary_profile="Ampestra"; fi; \
	if [ "$$notary_profile" = "-" ]; then notary_profile=""; fi; \
	{ \
		echo "SPARKLE_PUBLIC_ED_KEY=$$sparkle_key"; \
		echo "NOTARY_PROFILE=$$notary_profile"; \
	} > .env.release; \
	echo "Wrote .env.release"

sparkle-key: release-build
	.build/artifacts/sparkle/Sparkle/bin/generate_keys

notary-profile:
	xcrun notarytool store-credentials Ampestra

release-package:
	$(MAKE) release VERSION=$(VERSION)

clean:
	$(SWIFT) package clean
	rm -rf "Ampestra.app" dist
