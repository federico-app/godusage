SHELL := /bin/zsh
.DEFAULT_GOAL := help

# App iOS (GodUsageMobile): release locale su TestFlight, come sulle altre app.
# Versione = ultimo tag stabile vMAJOR.MINOR.PATCH (la stessa del Mac), build = numero di commit:
# lo stesso schema di script/release_ios.sh, quindi il progetto Xcode non viene mai modificato.
# Firma automatica con l'account Apple configurato in Xcode (team S6X72K86R8).

PROJECT := ios/GodUsageMobile.xcodeproj
TEAM_ID := S6X72K86R8
BUILD_ROOT := $(CURDIR)/dist/ios-local

# Il tag più alto, non `git describe`: i tag di release stanno su main, e da develop describe
# troverebbe un tag vecchio.
VERSION ?= $(shell git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$$' | head -1 | sed 's/^v//')
BUILD ?= $(shell git rev-list --count HEAD)

.PHONY: help build release release-dev _upload

help: ## Mostra i comandi disponibili
	@echo "GodUsage iOS — comandi disponibili"
	@echo ""
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "Versione: $(VERSION) (build $(BUILD)). Override: make release VERSION=x.y.z BUILD=n"

build: ## Compila l'app per il simulatore (verifica, senza firma)
	xcodebuild -project "$(PROJECT)" -target GodUsageMobile -configuration Debug \
		-sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

release: SCHEME := GodUsage
release: CONFIGURATION := Release
release: BUNDLE_ID := com.montinovo.godusage.mobile
release: FLAVOR := production
release: _upload ## Archivia GodUsage (produzione, api.godusage.com) e la carica su TestFlight

release-dev: SCHEME := GodUsage DEV
release-dev: CONFIGURATION := Dev
release-dev: BUNDLE_ID := com.montinovo.godusage.mobile.dev
release-dev: FLAVOR := dev
release-dev: _upload ## Archivia GodUsage DEV (api-dev.godusage.com) e la carica su TestFlight

_upload:
	@set -euo pipefail; \
	if [[ ! "$(VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then \
		echo "Errore: versione non valida '$(VERSION)' (atteso X.Y.Z dall'ultimo tag v*)." >&2; exit 1; \
	fi; \
	if [[ ! "$(BUILD)" =~ ^[0-9]+$$ ]]; then \
		echo "Errore: build non valida '$(BUILD)'." >&2; exit 1; \
	fi; \
	branch="$$(git branch --show-current)"; \
	echo "→ $(SCHEME) ($(BUNDLE_ID)) $(VERSION) build $(BUILD) dal branch $$branch @ $$(git rev-parse --short HEAD)"; \
	if [ "$(FLAVOR)" = "production" ] && [ "$$branch" != "main" ]; then \
		echo "⚠️  La produzione esce da main, ma sei su '$$branch'."; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "⚠️  Ci sono modifiche non committate: finiranno nella build."; \
	fi; \
	printf "Procedo con archive e upload su TestFlight? [y/N] "; read answer; \
	case "$$answer" in y|Y|yes|Yes|YES) ;; *) echo "❌ Release annullata"; exit 1 ;; esac; \
	OUT="$(BUILD_ROOT)/$(FLAVOR)"; \
	ARCHIVE_PATH="$$OUT/GodUsageMobile.xcarchive"; \
	EXPORT_OPTIONS="$$OUT/ExportOptions.plist"; \
	rm -rf "$$OUT"; mkdir -p "$$OUT"; \
	echo "→ Archive"; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "generic/platform=iOS" \
		-derivedDataPath "$$OUT/DerivedData" \
		-archivePath "$$ARCHIVE_PATH" \
		-allowProvisioningUpdates \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		MARKETING_VERSION="$(VERSION)" \
		CURRENT_PROJECT_VERSION="$(BUILD)" \
		clean archive; \
	got="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$ARCHIVE_PATH/Products/Applications/GodUsageMobile.app/Info.plist")"; \
	[ "$$got" = "$(BUNDLE_ID)" ] || { echo "Errore: l'archivio è '$$got', atteso '$(BUNDLE_ID)'." >&2; exit 1; }; \
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>destination</key><string>upload</string>' \
		'  <key>method</key><string>app-store-connect</string>' \
		'  <key>signingStyle</key><string>automatic</string>' \
		'  <key>teamID</key><string>$(TEAM_ID)</string>' \
		'  <key>uploadSymbols</key><true/>' \
		'  <key>manageAppVersionAndBuildNumber</key><false/>' \
		'</dict>' \
		'</plist>' > "$$EXPORT_OPTIONS"; \
	echo "→ Upload su App Store Connect"; \
	xcodebuild \
		-exportArchive \
		-archivePath "$$ARCHIVE_PATH" \
		-exportPath "$$OUT/export" \
		-exportOptionsPlist "$$EXPORT_OPTIONS" \
		-allowProvisioningUpdates; \
	echo "✓ $(SCHEME) $(VERSION) ($(BUILD)) caricata. TestFlight la rende disponibile appena Apple finisce il processing."
