import Cocoa
import SwiftUI

let app = NSApplication.shared
// Held by a top-level binding: NSApplication does not retain its delegate.
// Top-level code runs on the main thread, so main-actor isolation holds here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
