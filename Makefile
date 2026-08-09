# Kairos — a front end for launchd's user agents.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. SPM project, embedded Sparkle,
# dual-ship (.zip + .pkg).

BUNDLE_NAME      := Kairos
BUNDLE_TYPE      := app
PRODUCT_NAME     := Kairos.app
BUNDLE_ID        := cc.jorviksoftware.Kairos
BUILD_SYSTEM     := spm
SPM_PRODUCT      := Kairos

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := Kairos.entitlements

include ../jorvik-release/release.mk

# The icon is drawn by the SAME code the app uses at runtime, so it is compiled rather than run as a script.
# `swift generate_icon.swift` cannot see Sources/, and a second copy of the drawing would drift.
.PHONY: icon
icon:
	@mkdir -p .build/icongen && cp generate_icon.swift .build/icongen/main.swift
	@swiftc -O Sources/IconRenderer.swift .build/icongen/main.swift -o .build/icongen/gen
	@.build/icongen/gen
