import Cocoa
import SwiftUI

let app = NSApplication.shared
// Held by a top-level binding: NSApplication does not retain its delegate.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
