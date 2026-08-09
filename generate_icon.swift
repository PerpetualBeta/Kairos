// The icon generator. The DRAWING lives in Sources/IconRenderer.swift, because the running app redraws the
// same clock every minute for the Dock — two copies would drift and nobody would notice until they held a
// Dock icon next to a Finder one.
//
//     gmake icon
//
import Foundation
let base = FileManager.default.currentDirectoryPath
IconRenderer.writeIcns(base: base)
print("Done.")
