import ApplicationServices
import AppKit
import CoreGraphics

// Clean-room input synthesis via CoreGraphics events + Accessibility actions.
enum Input {
    static func moveAndClick(x: CGFloat, y: CGFloat, button: CGMouseButton = .left, count: Int = 1) {
        let pt = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .combinedSessionState)
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .right: return (.rightMouseDown, .rightMouseUp)
            case .center: return (.otherMouseDown, .otherMouseUp)
            default: return (.leftMouseDown, .leftMouseUp)
            }
        }()
        // move first
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(20_000)
        for i in 1...max(1, count) {
            let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: pt, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d?.post(tap: .cghidEventTap)
            let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: pt, mouseButton: button)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    static func drag(from: CGPoint, to: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        let steps = 12
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }

    static func scroll(dx: Int32, dy: Int32) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // key name -> (keycode, extra flags)
    static let keyMap: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]
    static let modMap: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "shift": .maskShift,
    ]

    /// Press a combo like "cmd+shift+t" or "return".
    static func pressCombo(_ combo: String) -> Bool {
        let parts = combo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyName: String? = nil
        for p in parts {
            if let f = modMap[p] { flags.insert(f) } else { keyName = p }
        }
        guard let kn = keyName, let code = keyMap[kn] else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        return true
    }

    // Accessibility-direct operations (preferred when available)
    static func axSetValue(_ el: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success
    }
    static func axPerform(_ el: AXUIElement, action: String) -> Bool {
        let a = action.hasPrefix("AX") ? action : "AX" + action
        return AXUIElementPerformAction(el, a as CFString) == .success
    }
    static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}
