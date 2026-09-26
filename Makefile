# Common entry points for the format corpus and the Godot remake slice.
#
# All export paths below are relative to godot/, because Godot resolves export
# destinations relative to the project passed to --path.

SHELL := /bin/sh

# Machine-local settings, gitignored: e.g. `LANGUAGE_PACKS = --language-pack
# "Russian=/path/to/1C" ...`, so every `make build-*` reuses the same data key
# instead of reconverting the data without the pack.
-include local.mk

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

.PHONY: help check-godot check-formats check-cache extract fixtures data \
	data-force _data-key \
	test-godot test-touch test-export test build build-macos build-windows \
	build-linux build-android build-ios

help:
	@printf '%s\n' \
		'Incubation commands:' \
		'  make check-formats  Verify every documented retail format (read-only).' \
		'  make check-cache    Verify the published remake cache.' \
		'  make extract        Extract sprites, textures, scripts, maps and skeletons to tools/out/.' \
		'  make fixtures       Rebuild ignored Godot test fixtures from the retail data.' \
		'  make test-godot     Run the Godot harness (requires fixtures and Godot 4.7).' \
		'  make test-touch     Run the viewport-level touch integration test.' \
		'  make test-export    Export the macOS Tests preset and run the suites inside it (needs a window).' \
		'  make test           Run format, cache, and Godot checks.' \
		'  make data           Convert the game data into godot/data/cache if it is out of date.' \
		'  make data-force     Rebuild it even when it looks current.' \
		'  make build          Build the host desktop target (macOS on this host).' \
		'  make build-macos    Export a macOS .app.' \
		'  make build-windows  Export a Windows x86_64 .exe.' \
		'  make build-linux    Export a Linux x86_64 executable.' \
		'  make build-android  Build an Android APK (ARMv7 + ARM64).' \
		'  make build-ios      Export an iOS Xcode project; configure a real Apple Team ID first.' \
		'' \
		'Every build-* carries the converted game data inside its own package (make data runs first).' \
		'Such a build contains Blue Byte data: it is for your own use, never for publishing.' \
		'NO_CACHE=1 builds without the data; that build reads a cache made with remake_convert.py -o.' \
		'' \
		'Default is a debug export. Android release needs local keystore credentials; iOS also needs Xcode.' \
		'Overrides: GODOT=/path/to/Godot GAME_ROOT=/path/to/retail-install PYTHON=python3 EXPORT_MODE=debug|release' \
		'           LANGUAGE_PACKS="--language-pack Russian=/path/to/1C ..." (part of the data key: changing it reconverts)'

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

extract:
	$(PYTHON) tools/extract_assets.py $(GAME_ROOT)

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

# The converted game data every build carries. `make data` writes it to
# ignored godot/data/cache with a keep-importer `.import` sidecar beside each
# PNG/WAV/OGG, and every export preset's include_filter takes the JSON
# documents, so a plain export puts the directory into the game's own package
# unimported: the PCK inside the .app, the .pck beside the .exe, the APK, the
# IPA (docs/92 section 10.1). It is never a repository asset.
#
# It is a build **product**, not a step: converting the whole campaign takes
# about a minute and 250 MiB, and every build used to pay it. It is rebuilt
# when the converter changes, when this file changes, or when the arguments it
# was built with change; `make data-force` rebuilds it unconditionally.
#
# The stamp is a file of its own and **not** the cache's own manifest: the
# converter refuses to replace a `cache/` directory that does not look like one
# of its own, so removing the manifest to force a rebuild leaves a directory
# nothing will overwrite. The manifest is still what says a cache is there at
# all, which is why the key check reads it.
DATA_DIR := $(GODOT_DIR)/data
DATA_MANIFEST := $(DATA_DIR)/cache/manifest.json
DATA_STAMP := $(DATA_DIR)/.cache-stamp
DATA_KEY := $(DATA_DIR)/.cache-build-key
# `LANGUAGE_PACKS` is the converter's own switches for the localisations the
# data carries -- e.g. `--language-pack Russian=/path/to/1C --plate
# Russian:title=/path/Title.bmp` -- and is part of the key, so data converted
# without a pack is stale once one is asked for.  Empty by default: a build
# made without it ships the base language only.
LANGUAGE_PACKS ?=
DATA_ARGS := $(GAME_ROOT) --campaign-maps --instant-action-maps $(LANGUAGE_PACKS)
CONVERTER_SOURCES := $(wildcard tools/*.py tools/inclib/*.py)

# `NO_CACHE=1` exports without the data, for a build that may leave this
# machine: `.gdignore` hides godot/data from the editor's filesystem for the
# length of the export, so no preset can pick it up, and the trap takes it
# away again however the export ends.
NO_CACHE ?=
ifeq ($(NO_CACHE),)
BUILD_DATA := data
else
BUILD_DATA :=
endif

# $(call godot_export,PRESET,OUTPUT) -- re-import first, so the export sees
# the data directory exactly as it is now (converted, or hidden by NO_CACHE).
define godot_export
	mkdir -p $(GODOT_DIR)/$(EXPORT_DIR)
	@if [ -n "$(NO_CACHE)" ]; then \
		mkdir -p $(DATA_DIR) && touch $(DATA_DIR)/.gdignore && \
		trap 'rm -f $(DATA_DIR)/.gdignore' EXIT INT TERM; \
	fi; \
	$(GODOT) --headless --path $(GODOT_DIR) --import && \
	$(GODOT) --headless --path $(GODOT_DIR) --export-$(EXPORT_MODE) $(1) $(EXPORT_DIR)/$(2)
endef

data:
	@$(MAKE) --no-print-directory _data-key
	@$(MAKE) --no-print-directory $(DATA_STAMP)

data-force:
	rm -f $(DATA_STAMP)
	@$(MAKE) --no-print-directory data

# Three things make prerequisites cannot see: data converted from another
# retail installation, data converted without `--instant-action-maps`, and a
# cache that has been removed under a stamp that stayed behind. All three are
# stale however new the stamp is.
_data-key:
	@if [ ! -f "$(DATA_MANIFEST)" ] \
			|| [ ! -f "$(DATA_KEY)" ] \
			|| [ "$$(cat "$(DATA_KEY)")" != '$(DATA_ARGS)' ]; then \
		rm -f "$(DATA_STAMP)"; \
	fi

$(DATA_STAMP): $(CONVERTER_SOURCES) $(MAKEFILE_LIST)
	$(PYTHON) tools/remake_convert.py $(DATA_ARGS) --dev-fixtures $(DATA_DIR)
	@printf '%s' '$(DATA_ARGS)' > "$(DATA_KEY)"
	@touch "$(DATA_STAMP)"

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

build-macos: check-godot $(BUILD_DATA)
	$(call godot_export,macOS,Incubation-remake.app)

build-windows: check-godot $(BUILD_DATA)
	$(call godot_export,Windows,Incubation-remake.exe)

build-linux: check-godot $(BUILD_DATA)
	$(call godot_export,Linux,Incubation-remake.x86_64)

build-android: check-godot $(BUILD_DATA)
	$(call godot_export,Android,Incubation-remake.apk)
ifeq ($(NO_CACHE),)
	$(PYTHON) tools/verify_embedded_cache.py $(GODOT_DIR)/$(EXPORT_DIR)/Incubation-remake.apk --expect-manifest $(DATA_MANIFEST)
else
	$(PYTHON) tools/verify_embedded_cache.py $(GODOT_DIR)/$(EXPORT_DIR)/Incubation-remake.apk --absent
endif

build-ios: check-godot $(BUILD_DATA)
	@test -n "$(IOS_TEAM_ID)" || { \
		echo 'build-ios: set application/app_store_team_id in godot/export_presets.cfg first.' >&2; exit 1; \
	}
	@test -d /Applications/Xcode.app || { \
		echo 'build-ios: Xcode is required; Command Line Tools alone cannot export iOS.' >&2; exit 1; \
	}
	$(call godot_export,iOS,Incubation-remake-ios.zip)
