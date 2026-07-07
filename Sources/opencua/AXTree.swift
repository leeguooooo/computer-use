import ApplicationServices
import AppKit

// Clean-room Accessibility-tree walker + serializer.
// Produces a compact, indented, index-addressed text view of a window's UI,
// designed to be read by a language model and referenced by element index.

struct AXNode {
    let element: AXUIElement
    let index: Int
    let depth: Int
    let role: String
    let roleDesc: String
    let label: String?
    let value: String?
    let help: String?
    let identifier: String?
    let settable: Bool
    let enabled: Bool
    let actions: [String]
    let frame: CGRect?
}

enum AX {
    static func str(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        // AXValue (point/size/bool)
        if let val = v, CFGetTypeID(val) == AXValueGetTypeID() {
            return describeAXValue(val as! AXValue)
        }
        return nil
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    static func actionNames(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyActionNames(el, &arr) == .success, let a = arr as? [String] else { return [] }
        // Drop the primary press-ish actions; keep the "secondary" ones as extra affordances.
        return a.filter { !["AXPress", "AXConfirm", "AXCancel"].contains($0) }
            .map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
    }

    static func settable(_ el: AXUIElement, _ attr: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &s) == .success && s.boolValue
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?
        var sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let p = pv, let s = sv,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static func describeAXValue(_ v: AXValue) -> String? {
        let t = AXValueGetType(v)
        switch t {
        case .cgPoint:
            var p = CGPoint.zero; AXValueGetValue(v, .cgPoint, &p); return "(\(Int(p.x)),\(Int(p.y)))"
        case .cgSize:
            var s = CGSize.zero; AXValueGetValue(v, .cgSize, &s); return "\(Int(s.width))x\(Int(s.height))"
        default: return nil
        }
    }
}

final class AXTreeSerializer {
    private(set) var nodes: [AXNode] = []
    private var counter = 0

    /// Walk `root` depth-first, assigning a stable per-snapshot integer index to each element.
    func walk(_ root: AXUIElement, depth: Int = 0) {
        let idx = counter
        counter += 1
        let role = AX.str(root, kAXRoleDescriptionAttribute) ?? AX.str(root, kAXRoleAttribute) ?? "element"
        let node = AXNode(
            element: root,
            index: idx,
            depth: depth,
            role: role.lowercased(),
            roleDesc: role,
            label: AX.str(root, kAXTitleAttribute) ?? AX.str(root, kAXDescriptionAttribute),
            value: AX.str(root, kAXValueAttribute),
            help: AX.str(root, kAXHelpAttribute),
            identifier: AX.str(root, kAXIdentifierAttribute),
            settable: AX.settable(root, kAXValueAttribute),
            enabled: AX.bool(root, kAXEnabledAttribute) ?? true,
            actions: AX.actionNames(root),
            frame: AX.frame(root)
        )
        nodes.append(node)
        for child in AX.children(root) {
            if counter > 4000 { return } // safety cap on huge trees
            walk(child, depth: depth + 1)
        }
    }

    /// Render the collected nodes into the compact indexed text format.
    func render() -> String {
        var out = ""
        for n in nodes {
            let indent = String(repeating: "\t", count: n.depth)
            var traits: [String] = []
            if !n.enabled { traits.append("disabled") }
            if n.settable { traits.append("settable") }
            var line = "\(indent)\(n.index) \(n.role)"
            if !traits.isEmpty { line += " (\(traits.joined(separator: ", ")))" }
            if let l = n.label, !l.isEmpty { line += " \"\(l)\"" }
            if let v = n.value, !v.isEmpty, v != n.label { line += " value=\(v)" }
            if let h = n.help, !h.isEmpty { line += " help=\(h)" }
            if let id = n.identifier, !id.isEmpty { line += " id=\(id)" }
            if !n.actions.isEmpty { line += " actions=[\(n.actions.joined(separator: ", "))]" }
            out += line + "\n"
        }
        return out
    }

    func node(at index: Int) -> AXNode? {
        nodes.first { $0.index == index }
    }
}
