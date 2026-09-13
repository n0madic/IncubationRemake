# Common entry points for the format corpus and the Godot remake slice.
#
# All export paths below are relative to godot/, because Godot resolves export
# destinations relative to the project passed to --path.

SHELL := /bin/sh

PYTHON ?= python3
GODOT ?= $(firstword $(wildcard /Applications/Godot.app/Contents/MacOS/Godot) $(shell command -v godot4 2>/dev/null) $(shell command -v godot 2>/dev/null))
GAME_ROOT ?= gog_incubation
GODOT_DIR := godot
EXPORT_DIR := export
EXPORT_MODE ?= debug
IOS_TEAM_ID := $(shell sed -n 's/^application\/app_store_team_id="\([^"]*\)"/\1/p' $(GODOT_DIR)/export_presets.cfg)

ifneq ($(filter $(EXPORT_MODE),debug release),$(EXPORT_MODE))
$(error EXPORT_MODE must be debug or release)
endif

.DEFAULT_GOAL := help

.PHONY: help check-godot check-formats check-cache fixtures android-cache \
	android-cache-force _android-cache-key \
	test-godot test-touch test-export test build build-macos build-windows \
	build-linux build-android build-ios

help:
	@printf '%s\n' \
		'Incubation commands:' \
		'  make check-formats  Verify every documented retail format (read-only).' \
		'  make check-cache    Verify the published remake cache.' \
		'  make fixtures       Rebuild ignored Godot test fixtures from the retail data.' \
		'  make test-godot     Run the Godot harness (requires fixtures and Godot 4.7).' \
		'  make test-touch     Run the viewport-level touch integration test.' \
		'  make test-export    Export the macOS Tests preset and run the suites inside it (needs a window).' \
		'  make test           Run format, cache, and Godot checks.' \
		'  make build          Build the host desktop target (macOS on this host).' \
		'  make build-macos    Export a macOS .app.' \
		'  make build-windows  Export a Windows x86_64 .exe.' \
		'  make build-linux    Export a Linux x86_64 executable.' \
		'  make android-cache  Build the Android payload cache if it is out of date.' \
		'  make android-cache-force  Rebuild it even when it looks current.' \
		'  make build-android  Build a self-contained Android APK (ARMv7 + ARM64).' \
		'  make build-ios      Export an iOS Xcode project; configure a real Apple Team ID first.' \
		'' \
		'Default is a debug export. Android release needs local keystore credentials; iOS also needs Xcode.' \
		'Overrides: GODOT=/path/to/Godot GAME_ROOT=/path/to/retail-install PYTHON=python3 EXPORT_MODE=debug|release' \
		'           LANGUAGE_PACKS="--language-pack Russian=/path/to/1C ..." (android-cache; empty = base language only)'

check-godot:
	@test -n "$(GODOT)" && test -x "$(GODOT)" || { \
		echo 'Godot 4.7 editor not found; set GODOT=/path/to/Godot.' >&2; exit 1; \
	}

# These commands only read GAME_ROOT.  Keeping the corpus gate separate from
# remake tests makes a mistyped or unavailable retail install fail explicitly.
check-formats:
	$(PYTHON) tools/lcl_parse.py $(GAME_ROOT) --check
	$(PYTHON) tools/lev_parse.py $(GAME_ROOT) --check
	$(PYTHON) tools/lib_extract.py $(GAME_ROOT) --check
	$(PYTHON) tools/visn_decode.py $(GAME_ROOT) --check
	$(PYTHON) tools/prototyp_parse.py --check --root $(GAME_ROOT)
	$(PYTHON) tools/cho_parse.py --check $(GAME_ROOT)
	$(PYTHON) tools/cha_parse.py --check $(GAME_ROOT)
	$(PYTHON) tools/cha_parse.py --verify-convention $(GAME_ROOT)
	$(PYTHON) tools/font_render.py --check $(GAME_ROOT)
	$(PYTHON) tools/img_tables.py $(GAME_ROOT)
	$(PYTHON) tools/verify_3d_indices.py --root $(GAME_ROOT)
	$(PYTHON) tools/combat_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/trace_names.py --check $(GAME_ROOT)
	$(PYTHON) tools/sav_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/sav_parse.py $(GAME_ROOT) --selftest
	$(PYTHON) tools/typ_parse.py --check $(GAME_ROOT)
	$(PYTHON) tools/ai_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/brief_parse.py --check $(GAME_ROOT)
	$(PYTHON) tools/turn_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/interaction_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/campaign_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/blob_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/blob_runtime.py --selftest
	$(PYTHON) tools/pe_exports.py --check $(GAME_ROOT)
	$(PYTHON) tools/interface_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/charisma_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/presentation_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/seq_parse.py $(GAME_ROOT) --check
	$(PYTHON) tools/hud_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/language_tables.py --check $(GAME_ROOT)
	$(PYTHON) tools/charisma_selftest.py
	$(PYTHON) tools/dbgcall_patches.py $(GAME_ROOT) --selftest
	$(PYTHON) tools/info_parse.py --check $(GAME_ROOT)
	$(PYTHON) tools/lcl_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/turn_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/combat_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/interact_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/movemap_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/ai_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/campaign_runtime.py --check $(GAME_ROOT)
	$(PYTHON) tools/remake_convert.py $(GAME_ROOT) --check

check-cache:
	$(PYTHON) tools/remake_convert.py --check-cache

fixtures:
	$(PYTHON) tools/remake_convert.py $(GAME_ROOT) --dev-fixtures $(GODOT_DIR)/generated
	$(PYTHON) tools/movemap_runtime.py --emit-cases tests/fixtures/movemap --root $(GAME_ROOT)
	$(PYTHON) tools/turn_gold.py --emit-cases tests/fixtures/turn/cases_turn.json --root $(GAME_ROOT)
	$(PYTHON) tools/turn_runtime.py --check $(GAME_ROOT) --emit-handover-cases tests/fixtures/turn/cases_handover.json
	$(PYTHON) tools/movemap_gold.py --emit-allowance-cases tests/fixtures/movemap/cases_allowance.json
	$(PYTHON) tools/movemap_gold.py --selftest-process-scope
	$(PYTHON) tools/lcl_runtime.py --emit-cases tests/fixtures/lcl/cases_lcl.json --root $(GAME_ROOT)
	$(PYTHON) tools/charisma_tables.py $(GAME_ROOT) --emit-pose-cases tests/fixtures/charisma/cases_pose.json
	$(PYTHON) tools/ai_runtime.py --emit-cases tests/fixtures/ai/cases_ai.json --root $(GAME_ROOT)
	$(PYTHON) tools/blob_tables.py --emit-sound-cases tests/fixtures/sound/cases_sound.json --root $(GAME_ROOT)
	$(PYTHON) tools/blob_runtime.py --emit-cases tests/fixtures/blob/cases_blob.json --root $(GAME_ROOT)
	$(PYTHON) tools/campaign_runtime.py --emit-cases tests/fixtures/campaign/cases_campaign.json --root $(GAME_ROOT)
	$(PYTHON) tools/presentation_gold.py --emit-death-cases tests/fixtures/presentation/cases_death.json --root $(GAME_ROOT)
	$(PYTHON) tools/presentation_gold.py --emit-idle-cases tests/fixtures/presentation/cases_idle.json --root $(GAME_ROOT)
	$(PYTHON) tools/presentation_gold.py --emit-special-cases tests/fixtures/presentation/cases_special.json --root $(GAME_ROOT)
	$(PYTHON) tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json --root $(GAME_ROOT)

# Android builds are standalone: the cache is regenerated from the supplied
# retail installation and then checked inside the APK file by file. It
# stays in ignored godot/android_payload/ and is never a repository asset.
#
# It is a build **product**, not a step: converting the whole campaign takes
# about a minute and 200 MiB, and `build-android` used to pay it on every
# export. It is rebuilt when the converter changes, when this file changes, or
# when the arguments it was built with change; `make android-cache-force`
# rebuilds it unconditionally.
#
# The stamp is a file of its own and **not** the cache's own manifest: the
# converter refuses to replace a `cache/` directory that does not look like one
# of its own, so removing the manifest to force a rebuild leaves a payload
# nothing will overwrite. The manifest is still what says a cache is there at
# all, which is why the key check reads it.
ANDROID_PAYLOAD := $(GODOT_DIR)/android_payload
ANDROID_CACHE_MANIFEST := $(ANDROID_PAYLOAD)/cache/manifest.json
ANDROID_CACHE_STAMP := $(ANDROID_PAYLOAD)/.cache-stamp
ANDROID_CACHE_KEY := $(ANDROID_PAYLOAD)/.cache-build-key
# `LANGUAGE_PACKS` is the converter's own switches for the localisations the
# payload carries -- e.g. `--language-pack Russian=/path/to/1C --plate
# Russian:title=/path/Title.bmp` -- and is part of the key, so a payload
# converted without a pack is stale once one is asked for.  Empty by default:
# an APK built without it ships the base language only.
LANGUAGE_PACKS ?=
ANDROID_CACHE_ARGS := $(GAME_ROOT) --campaign-maps --instant-action-maps $(LANGUAGE_PACKS)
CONVERTER_SOURCES := $(wildcard tools/*.py tools/inclib/*.py)

android-cache:
	@$(MAKE) --no-print-directory _android-cache-key
	@$(MAKE) --no-print-directory $(ANDROID_CACHE_STAMP)

android-cache-force:
	rm -f $(ANDROID_CACHE_STAMP)
	@$(MAKE) --no-print-directory android-cache

# Three things make prerequisites cannot see: a payload converted from another
# retail installation, one converted without `--instant-action-maps`, and one
# whose cache has been removed under a stamp that stayed behind. All three are
# stale however new the stamp is.
_android-cache-key:
	@if [ ! -f "$(ANDROID_CACHE_MANIFEST)" ] \
			|| [ ! -f "$(ANDROID_CACHE_KEY)" ] \
			|| [ "$$(cat "$(ANDROID_CACHE_KEY)")" != "$(ANDROID_CACHE_ARGS)" ]; then \
		rm -f "$(ANDROID_CACHE_STAMP)"; \
	fi

$(ANDROID_CACHE_STAMP): $(CONVERTER_SOURCES) $(MAKEFILE_LIST)
	$(PYTHON) tools/remake_convert.py $(ANDROID_CACHE_ARGS) --dev-fixtures $(ANDROID_PAYLOAD)
	# Cache files are verified as original bytes at run time, so keep Godot's
	# importer out of this build-only subtree. The Android export plugin writes
	# each manifest file as raw data into the package. The conversion renames a
	# whole staging directory into place, so this is written after every one.
	touch $(ANDROID_PAYLOAD)/cache/.gdignore
	@printf '%s' '$(ANDROID_CACHE_ARGS)' > "$(ANDROID_CACHE_KEY)"
	@touch "$(ANDROID_CACHE_STAMP)"

test-godot: check-godot
	bash $(GODOT_DIR)/run_tests.sh $(GODOT)

test-touch: check-godot
	$(GODOT) --headless --fixed-fps 60 --path $(GODOT_DIR) --script res://tests/touch_integration.gd -- --mission=_C_140

# Out of `make test` like `test-touch`: it needs export templates and a
# window, and takes three minutes. Always a debug export -- the leak gate it
# exists for reads diagnostics a release template strips -- so EXPORT_MODE is
# not passed on.
test-export: check-godot
	bash $(GODOT_DIR)/run_export_tests.sh $(GODOT)

test: check-formats check-cache test-godot

build: build-macos

build-macos: check-godot
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) macOS $(EXPORT_DIR)/Incubation-remake.app

build-windows: check-godot
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) Windows $(EXPORT_DIR)/Incubation-remake.exe

build-linux: check-godot
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) Linux $(EXPORT_DIR)/Incubation-remake.x86_64

build-android: check-godot android-cache
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) Android $(EXPORT_DIR)/Incubation-remake.apk
	$(PYTHON) tools/verify_embedded_cache.py $(GODOT_DIR)/$(EXPORT_DIR)/Incubation-remake.apk

build-ios: check-godot
	@test -n "$(IOS_TEAM_ID)" || { \
		echo 'build-ios: set application/app_store_team_id in godot/export_presets.cfg first.' >&2; exit 1; \
	}
	@test -d /Applications/Xcode.app || { \
		echo 'build-ios: Xcode is required; Command Line Tools alone cannot export iOS.' >&2; exit 1; \
	}
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) iOS $(EXPORT_DIR)/Incubation-remake-ios.zip
