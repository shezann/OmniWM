// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

// A separate process is essential: WindowServer transactions can move owned windows
// while silently leaving foreign application windows unchanged.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(
    contentRect: CGRect(x: -9000, y: -9000, width: 160, height: 120),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.orderFrontRegardless()
try String(window.windowNumber).write(
    toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8
)
Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in exit(0) }
app.run()
