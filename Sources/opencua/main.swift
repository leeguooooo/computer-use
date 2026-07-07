import Foundation
import AppKit
import CoreGraphics

// opencua — Open Computer Use. A clean-room macOS UI automation CLI:
// accessibility-tree + screenshot state, CGEvent input, exposed over MCP.

let args = Array(CommandLine.arguments.dropFirst())

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

func requireAX() {
    if !Permissions.axTrusted {
        Permissions.promptAX()
        die("accessibility permission not granted. Grant opencua's host (Terminal/iTerm) in System Settings → Privacy & Security → Accessibility, then retry.")
    }
}

func printUsage() {
    print("""
    opencua <command>

    permissions              Show/prompt Accessibility + Screen Recording access
    apps                     List running apps with windows
    state <app> [--no-shot]  Dump accessibility tree (+ save screenshot to /tmp)
    click <app> <index>      Click element by index
    click <app> --x N --y N  Click at window-relative pixel coords
    type  <app> <text...>    Type literal text
    key   <app> <combo>      Press a key/combo, e.g. cmd+s, return
    scroll <app> <index> <up|down|left|right> [pages]
    setvalue <app> <index> <value...>
    action <app> <index> <ActionName>
    mcp                      Run as an MCP (stdio JSON-RPC) server
    """)
}

func resolvePoint(_ s: Snapshot, index: Int?, x: Double?, y: Double?) -> CGPoint? {
    if let idx = index, let node = s.serializer.node(at: idx), let f = node.frame {
        return Input.center(of: f)
    }
    if let x = x, let y = y, let wf = s.windowFrame {
        return CGPoint(x: wf.origin.x + x, y: wf.origin.y + y)
    }
    if let x = x, let y = y { return CGPoint(x: x, y: y) }
    return nil
}

guard let cmd = args.first else { printUsage(); exit(0) }

switch cmd {
case "-h", "--help", "help":
    printUsage()

case "permissions":
    print("accessibility:     \(Permissions.axTrusted ? "granted" : "NOT granted")")
    print("screen_recording:  \(Permissions.screenRecording ? "granted" : "NOT granted")")
    if !Permissions.axTrusted { Permissions.promptAX() }
    if !Permissions.screenRecording { Permissions.promptScreenRecording() }

case "apps":
    requireAX()
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
        print("\(a.localizedName ?? "?")  [\(a.bundleIdentifier ?? "?")]  pid=\(a.processIdentifier)")
    }

case "state":
    requireAX()
    guard args.count >= 2 else { die("usage: state <app>") }
    let wantShot = !args.contains("--no-shot")
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: wantShot)
        print(AppStateBuilder.renderText(s))
        if let b64 = s.screenshotPNGBase64, let data = Data(base64Encoded: b64) {
            let p = "/tmp/opencua-shot.png"
            try? data.write(to: URL(fileURLWithPath: p))
            if let px = s.pixelSize { print("screenshot: \(p)  (\(Int(px.width))x\(Int(px.height)))") }
        }
    } catch { die("error: \(error)") }

case "click":
    requireAX()
    guard args.count >= 2 else { die("usage: click <app> <index> | --x N --y N") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false)
        let idx = args.count >= 3 && Int(args[2]) != nil ? Int(args[2]) : nil
        let x = flagVal("--x").map { Double($0) ?? 0 }
        let y = flagVal("--y").map { Double($0) ?? 0 }
        // Faithful to Codex: real coordinate mouse click (focuses text fields);
        // AXPress only as a fallback when the element exposes no frame.
        if let idx = idx, let node = s.serializer.node(at: idx) {
            if let f = node.frame { Input.moveAndClick(x: f.midX, y: f.midY); print("clicked \(idx) at \(Int(f.midX)),\(Int(f.midY))"); break }
            if Input.axPerform(node.element, action: "Press") { print("pressed \(idx) via AX"); break }
        }
        guard let pt = resolvePoint(s, index: idx, x: x, y: y) else { die("need <index> or --x/--y") }
        Input.moveAndClick(x: pt.x, y: pt.y)
        print("clicked \(Int(pt.x)),\(Int(pt.y))")
    } catch { die("error: \(error)") }

case "type":
    requireAX()
    guard args.count >= 3 else { die("usage: type <app> <text...>") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false)
        _ = s
        Input.typeText(args[2...].joined(separator: " "))
        print("typed")
    } catch { die("error: \(error)") }

case "key":
    requireAX()
    guard args.count >= 3 else { die("usage: key <app> <combo>") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false); _ = s
        if Input.pressCombo(args[2]) { print("pressed \(args[2])") } else { die("unknown key: \(args[2])") }
    } catch { die("error: \(error)") }

case "scroll":
    requireAX()
    guard args.count >= 4, let idx = Int(args[2]) else { die("usage: scroll <app> <index> <dir> [pages]") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false)
        if let node = s.serializer.node(at: idx), let f = node.frame {
            Input.moveAndClick(x: f.midX, y: f.midY, count: 0) // just move cursor over the element
        }
        let pages = args.count >= 5 ? (Int(args[4]) ?? 1) : 1
        let mag: Int32 = Int32(10 * pages)
        switch args[3] {
        case "up": Input.scroll(dx: 0, dy: mag)
        case "down": Input.scroll(dx: 0, dy: -mag)
        case "left": Input.scroll(dx: mag, dy: 0)
        case "right": Input.scroll(dx: -mag, dy: 0)
        default: die("dir must be up/down/left/right")
        }
        print("scrolled \(args[3]) \(pages)")
    } catch { die("error: \(error)") }

case "setvalue":
    requireAX()
    guard args.count >= 4, let idx = Int(args[2]) else { die("usage: setvalue <app> <index> <value...>") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false)
        guard let node = s.serializer.node(at: idx) else { die("no element \(idx)") }
        let val = args[3...].joined(separator: " ")
        print(Input.axSetValue(node.element, val) ? "set" : "failed to set")
    } catch { die("error: \(error)") }

case "action":
    requireAX()
    guard args.count >= 4, let idx = Int(args[2]) else { die("usage: action <app> <index> <ActionName>") }
    do {
        let s = try AppStateBuilder.build(app: args[1], screenshot: false)
        guard let node = s.serializer.node(at: idx) else { die("no element \(idx)") }
        print(Input.axPerform(node.element, action: args[3]) ? "performed" : "failed")
    } catch { die("error: \(error)") }

case "windows":
    requireAX()
    guard let running = Apps.find(args[1]) else { die("app not found") }
    let appEl = AXUIElementCreateApplication(running.processIdentifier)
    print("app role = \(AX.str(appEl, kAXRoleAttribute) ?? "nil")")
    for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, attr as CFString, &v)
        var roleInfo = "nil"
        if err == .success, let w = v, CFGetTypeID(w) == AXUIElementGetTypeID() {
            roleInfo = AX.str(w as! AXUIElement, kAXRoleAttribute) ?? "nil"
        }
        print("\(attr): err=\(err.rawValue) role=\(roleInfo)")
    }
    var wv: CFTypeRef?
    let werr = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wv)
    let arr = (wv as? [AXUIElement]) ?? []
    print("kAXWindows: err=\(werr.rawValue) count=\(arr.count)")
    for (i, w) in arr.enumerated() {
        print("  [\(i)] role=\(AX.str(w, kAXRoleAttribute) ?? "nil") title=\(AX.str(w, kAXTitleAttribute) ?? "nil")")
    }

case "mcp":
    MCPServer().run()

default:
    printUsage()
    exit(1)
}

func flagVal(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}
