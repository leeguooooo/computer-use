import Foundation

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Exposes the opencua automation surface as MCP tools.
final class MCPServer {
    let serverName = "opencua"
    let serverVersion = "0.1.0"

    func run() {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(msg)
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    private func result(_ id: Any?, _ result: [String: Any]) {
        var o: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { o["id"] = id }
        send(o)
    }

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        switch method {
        case "initialize":
            result(id, [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Computer Use (opencua)", "version": serverVersion],
            ])
        case "notifications/initialized", "notifications/cancelled":
            break // notifications: no response
        case "tools/list":
            result(id, ["tools": Tools.definitions])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let content = Tools.call(name: name, args: arguments)
            result(id, ["content": content.blocks, "isError": content.isError])
        case "ping":
            result(id, [:])
        default:
            if id != nil {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]])
            }
        }
    }
}

struct ToolResult { let blocks: [[String: Any]]; let isError: Bool }

enum Tools {
    static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    static let appProp: [String: Any] = ["type": "string", "description": "App name, full path, or bundle identifier"]
    static let idxProp: [String: Any] = ["type": "string", "description": "Element index from the accessibility tree"]

    static var definitions: [[String: Any]] {
        [
            tool("list_apps", "List running apps that have windows.", props: [:], required: []),
            tool("get_app_state",
                 "Activate the app, then return its key window's accessibility tree plus a screenshot. Call once per turn before interacting.",
                 props: ["app": appProp], required: ["app"]),
            tool("click", "Click an element by index, or by window-relative pixel x/y.",
                 props: ["app": appProp, "element_index": idxProp,
                         "x": ["type": "number"], "y": ["type": "number"],
                         "button": ["type": "string", "enum": ["left", "right", "middle"]]],
                 required: ["app"]),
            tool("type_text", "Type literal text via the keyboard.",
                 props: ["app": appProp, "text": ["type": "string"]], required: ["app", "text"]),
            tool("press_key", "Press a key or combo, e.g. 'cmd+s', 'return', 'cmd+shift+t'.",
                 props: ["app": appProp, "key": ["type": "string"]], required: ["app", "key"]),
            tool("scroll", "Scroll an element in a direction by N pages.",
                 props: ["app": appProp, "element_index": idxProp,
                         "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                         "pages": ["type": "number"]],
                 required: ["app", "element_index", "direction"]),
            tool("set_value", "Set the value of a settable element directly (no typing).",
                 props: ["app": appProp, "element_index": idxProp, "value": ["type": "string"]],
                 required: ["app", "element_index", "value"]),
            tool("perform_action", "Invoke a secondary accessibility action exposed by an element.",
                 props: ["app": appProp, "element_index": idxProp, "action": ["type": "string"]],
                 required: ["app", "element_index", "action"]),
        ]
    }

    static func tool(_ name: String, _ desc: String, props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
    }

    static func call(name: String, args: [String: Any]) -> ToolResult {
        if !Permissions.axTrusted {
            Permissions.promptAX()
            return ToolResult(blocks: [text("error: accessibility permission not granted. Grant the host app in System Settings → Privacy & Security → Accessibility.")], isError: true)
        }
        let app = args["app"] as? String ?? ""
        do {
            switch name {
            case "list_apps":
                let list = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .map { "\($0.localizedName ?? "?")  [\($0.bundleIdentifier ?? "?")]" }
                    .joined(separator: "\n")
                return ToolResult(blocks: [text(list)], isError: false)

            case "get_app_state":
                let s = try AppStateBuilder.build(app: app, screenshot: true)
                var blocks: [[String: Any]] = [text(AppStateBuilder.renderText(s))]
                if let jpg = s.screenshotJPEGBase64 {
                    blocks.append(["type": "image", "data": jpg, "mimeType": "image/jpeg"])
                }
                return ToolResult(blocks: blocks, isError: false)

            case "click":
                let s = try AppStateBuilder.build(app: app, screenshot: false)
                if let idxStr = args["element_index"] as? String, let idx = Int(idxStr),
                   let node = s.serializer.node(at: idx) {
                    if let f = node.frame {
                        Input.moveAndClick(x: f.midX, y: f.midY, button: mouseButton(args))
                        return ToolResult(blocks: [text("clicked element \(idx)")], isError: false)
                    }
                    if Input.axPerform(node.element, action: "Press") {
                        return ToolResult(blocks: [text("pressed element \(idx)")], isError: false)
                    }
                }
                if let x = args["x"] as? Double, let y = args["y"] as? Double, let wf = s.windowFrame {
                    Input.moveAndClick(x: wf.origin.x + x, y: wf.origin.y + y, button: mouseButton(args))
                    return ToolResult(blocks: [text("clicked (\(Int(x)),\(Int(y)))")], isError: false)
                }
                return ToolResult(blocks: [text("error: need element_index or x/y")], isError: true)

            case "type_text":
                _ = try AppStateBuilder.build(app: app, screenshot: false)
                Input.typeText(args["text"] as? String ?? "")
                return ToolResult(blocks: [text("typed")], isError: false)

            case "press_key":
                _ = try AppStateBuilder.build(app: app, screenshot: false)
                let k = args["key"] as? String ?? ""
                return Input.pressCombo(k)
                    ? ToolResult(blocks: [text("pressed \(k)")], isError: false)
                    : ToolResult(blocks: [text("unknown key: \(k)")], isError: true)

            case "scroll":
                let s = try AppStateBuilder.build(app: app, screenshot: false)
                if let idxStr = args["element_index"] as? String, let idx = Int(idxStr),
                   let node = s.serializer.node(at: idx), let f = node.frame {
                    Input.moveAndClick(x: f.midX, y: f.midY, count: 0)
                }
                let pages = Int(args["pages"] as? Double ?? 1)
                let mag = Int32(10 * max(1, pages))
                switch args["direction"] as? String {
                case "up": Input.scroll(dx: 0, dy: mag)
                case "down": Input.scroll(dx: 0, dy: -mag)
                case "left": Input.scroll(dx: mag, dy: 0)
                case "right": Input.scroll(dx: -mag, dy: 0)
                default: return ToolResult(blocks: [text("bad direction")], isError: true)
                }
                return ToolResult(blocks: [text("scrolled")], isError: false)

            case "set_value":
                let s = try AppStateBuilder.build(app: app, screenshot: false)
                guard let idxStr = args["element_index"] as? String, let idx = Int(idxStr),
                      let node = s.serializer.node(at: idx) else {
                    return ToolResult(blocks: [text("no such element")], isError: true)
                }
                let ok = Input.axSetValue(node.element, args["value"] as? String ?? "")
                return ToolResult(blocks: [text(ok ? "value set" : "failed to set value")], isError: !ok)

            case "perform_action":
                let s = try AppStateBuilder.build(app: app, screenshot: false)
                guard let idxStr = args["element_index"] as? String, let idx = Int(idxStr),
                      let node = s.serializer.node(at: idx) else {
                    return ToolResult(blocks: [text("no such element")], isError: true)
                }
                let ok = Input.axPerform(node.element, action: args["action"] as? String ?? "")
                return ToolResult(blocks: [text(ok ? "action performed" : "action failed")], isError: !ok)

            default:
                return ToolResult(blocks: [text("unknown tool: \(name)")], isError: true)
            }
        } catch {
            return ToolResult(blocks: [text("error: \(error)")], isError: true)
        }
    }

    static func mouseButton(_ args: [String: Any]) -> CGMouseButton {
        switch args["button"] as? String {
        case "right": return .right
        case "middle": return .center
        default: return .left
        }
    }
}

import AppKit
import CoreGraphics
