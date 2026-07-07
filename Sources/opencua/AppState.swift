import ApplicationServices
import AppKit
import CoreGraphics

struct Snapshot {
    let appName: String
    let bundleID: String
    let pid: pid_t
    let windowTitle: String
    let tree: String
    let focusedIndex: Int?
    let serializer: AXTreeSerializer
    let window: AXUIElement
    let windowFrame: CGRect?
    let screenshotPNGBase64: String?
    let screenshotJPEGBase64: String?
    let pixelSize: CGSize?
}

enum AppStateError: Error, CustomStringConvertible {
    case notTrusted
    case appNotFound(String)
    case noWindow
    var description: String {
        switch self {
        case .notTrusted: return "accessibility_not_granted"
        case .appNotFound(let a): return "app_not_found: \(a)"
        case .noWindow: return "no_window"
        }
    }
}

enum Permissions {
    static var axTrusted: Bool { AXIsProcessTrusted() }
    static func promptAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static func promptScreenRecording() { _ = CGRequestScreenCaptureAccess() }
}

enum Apps {
    static func find(_ query: String) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let q = query.lowercased()
        // exact bundle id
        if let a = running.first(where: { $0.bundleIdentifier?.lowercased() == q }) { return a }
        // exact name
        if let a = running.first(where: { $0.localizedName?.lowercased() == q }) { return a }
        // full path
        if query.hasPrefix("/"), let a = running.first(where: { $0.bundleURL?.path == query || $0.executableURL?.path == query }) { return a }
        // fuzzy contains
        return running.first(where: { ($0.localizedName?.lowercased().contains(q) ?? false)
            || ($0.bundleIdentifier?.lowercased().contains(q) ?? false) })
    }
}

enum AppStateBuilder {
    private static func isWindow(_ el: AXUIElement) -> Bool {
        (AX.str(el, kAXRoleAttribute) ?? "") == (kAXWindowRole as String)
    }

    private static func windowAttr(_ appEl: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, attr as CFString, &v) == .success,
              let w = v, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let el = w as! AXUIElement
        return isWindow(el) ? el : nil
    }

    static func keyWindow(of appEl: AXUIElement) -> AXUIElement? {
        // Only accept a real AXWindow; if none, the app has no key window.
        if let w = windowAttr(appEl, kAXMainWindowAttribute) { return w }
        if let w = windowAttr(appEl, kAXFocusedWindowAttribute) { return w }
        var wv: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wv) == .success,
           let arr = wv as? [AXUIElement], let first = arr.first(where: isWindow) { return first }
        return nil
    }

    static func build(app query: String, screenshot: Bool = true) throws -> Snapshot {
        guard Permissions.axTrusted else { throw AppStateError.notTrusted }
        guard let running = Apps.find(query) else { throw AppStateError.appNotFound(query) }
        running.activate(options: [])
        usleep(120_000)
        let pid = running.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        guard let win = keyWindow(of: appEl) else { throw AppStateError.noWindow }

        let ser = AXTreeSerializer()
        ser.walk(win)
        let tree = ser.render()
        let title = AX.str(win, kAXTitleAttribute) ?? "(untitled)"

        // focused element -> match to an index if present in the tree
        var focusedIndex: Int? = nil
        var fv: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &fv) == .success,
           let f = fv, CFGetTypeID(f) == AXUIElementGetTypeID() {
            let fel = f as! AXUIElement
            focusedIndex = ser.nodes.first(where: { CFEqual($0.element, fel) })?.index
        }

        let frame = AX.frame(win)
        var pngB64: String? = nil
        var jpgB64: String? = nil
        var pxSize: CGSize? = nil
        if screenshot, let rect = frame, Permissions.screenRecording {
            if let img = captureRect(rect) {
                pxSize = CGSize(width: img.width, height: img.height)
                let rep = NSBitmapImageRep(cgImage: img)
                pngB64 = rep.representation(using: .png, properties: [:])?.base64EncodedString()
                jpgB64 = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])?.base64EncodedString()
            }
        }

        return Snapshot(appName: running.localizedName ?? query,
                        bundleID: running.bundleIdentifier ?? "?",
                        pid: pid, windowTitle: title, tree: tree,
                        focusedIndex: focusedIndex, serializer: ser, window: win,
                        windowFrame: frame, screenshotPNGBase64: pngB64,
                        screenshotJPEGBase64: jpgB64, pixelSize: pxSize)
    }

    static func captureRect(_ rect: CGRect) -> CGImage? {
        // MVP: capture the on-screen region occupied by the window.
        // (ScreenCaptureKit is the modern path; region capture keeps the MVP simple.)
        return CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    /// Human/LM-readable rendering of a snapshot (text channel).
    static func renderText(_ s: Snapshot) -> String {
        var out = "opencua app state\n<app_state>\n"
        out += "App=\(s.appName) (bundleID \(s.bundleID), pid \(s.pid))\n"
        out += "Window: \"\(s.windowTitle)\"\n"
        out += s.tree
        if let f = s.focusedIndex { out += "focused element index = \(f)\n" }
        out += "</app_state>\n"
        return out
    }
}
