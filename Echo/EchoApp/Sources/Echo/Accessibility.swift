import AppKit
import ApplicationServices

/// Thin wrappers over the Accessibility C API. All coordinates are AX global coordinates: origin at the
/// top-left of the primary screen, y growing downward.
extension AXUIElement {
    func value(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    func string(_ name: String) -> String? { value(name) as? String }
    func int(_ name: String) -> Int? { (value(name) as? NSNumber)?.intValue }

    func element(_ name: String) -> AXUIElement? {
        guard let value = value(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var role: String? { string(kAXRoleAttribute) }
    var parent: AXUIElement? { element(kAXParentAttribute) }
    var children: [AXUIElement] { (value(kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    var frame: CGRect? {
        guard let origin: CGPoint = Self.unpack(value(kAXPositionAttribute), .cgPoint),
              let size: CGSize = Self.unpack(value(kAXSizeAttribute), .cgSize) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var position: CGPoint? { Self.unpack(value(kAXPositionAttribute), .cgPoint) }

    func range(_ name: String) -> NSRange? {
        guard let r: CFRange = Self.unpack(value(name), .cfRange) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    func supportsParameterized(_ name: String) -> Bool {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(self, &names)
        return (names as? [String])?.contains(name) ?? false
    }

    /// Screen rect of a character range; nil if the app can't say.
    func bounds(for range: NSRange) -> CGRect? {
        var r = CFRange(location: range.location, length: range.length)
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         arg, &value) == .success else { return nil }
        return Self.unpack(value, .cgRect)
    }

    func isSame(as other: AXUIElement?) -> Bool {
        guard let other else { return false }
        return CFEqual(self, other)
    }

    private static func unpack<T>(_ value: CFTypeRef?, _ type: AXValueType) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(ax, type, pointer) ? pointer.pointee : nil
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open Privacy & Security › Accessibility.
    static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, which Swift 6 flags as mutable global state
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The document editor in `window`: the largest text area that reports character bounds. Writing apps
    /// keep focus in a sidebar (Scrivener's binder) after you pick a document, so focus alone isn't enough.
    static func largestTextArea(in window: AXUIElement, maxNodes: Int = 4000) -> AXUIElement? {
        var queue = [window]
        var index = 0
        var best: (element: AXUIElement, length: Int)?
        // Outlines, tables and lists (the binder, corkboard, outliner) can hold thousands of rows.
        let skipped: Set<String> = [kAXOutlineRole, kAXTableRole, kAXListRole, kAXBrowserRole, kAXMenuBarRole, kAXToolbarRole]
        while index < queue.count, index < maxNodes {
            let element = queue[index]
            index += 1
            let role = element.role
            if role == kAXTextAreaRole, isEditor(element) {
                let length = element.int(kAXNumberOfCharactersAttribute) ?? 0
                if best == nil || length > best!.length { best = (element, length) }
                continue
            }
            if let role, skipped.contains(role) { continue }
            queue += element.children
        }
        return best?.element
    }

    static func isEditor(_ element: AXUIElement) -> Bool {
        element.role == kAXTextAreaRole && element.supportsParameterized(kAXBoundsForRangeParameterizedAttribute)
    }

    /// The nearest enclosing scroll area: highlights are clipped to it so they never spill over rulers,
    /// toolbars or footers.
    static func scrollArea(containing element: AXUIElement) -> AXUIElement? {
        var current = element.parent
        for _ in 0..<8 {
            guard let el = current else { return nil }
            if el.role == kAXScrollAreaRole { return el }
            current = el.parent
        }
        return nil
    }

    /// The part of a scroll area that shows text: its frame minus rulers and scroll bars along the edges.
    /// Scrivener's ruler lives inside the editor's scroll area.
    static func contentFrame(of scrollArea: AXUIElement) -> CGRect? {
        guard var clip = scrollArea.frame else { return nil }
        for child in scrollArea.children {
            guard let role = child.role, role == kAXRulerRole || role == kAXScrollBarRole,
                  let bar = child.frame, bar.intersects(clip) else { continue }
            if bar.width >= bar.height {   // horizontal: trim top or bottom
                if bar.midY < clip.midY { clip = CGRect(x: clip.minX, y: bar.maxY, width: clip.width, height: clip.maxY - bar.maxY) }
                else { clip.size.height = bar.minY - clip.minY }
            } else {                       // vertical: trim left or right
                if bar.midX < clip.midX { clip = CGRect(x: bar.maxX, y: clip.minY, width: clip.maxX - bar.maxX, height: clip.height) }
                else { clip.size.width = bar.minX - clip.minX }
            }
        }
        return clip
    }
}

/// Converts between AX coordinates (top-left origin) and Cocoa screen coordinates (bottom-left origin).
extension CGRect {
    var flippedToCocoa: CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: height - maxY, width: width, height: self.height)
    }
}

extension CGRect {
    /// Cocoa screen rect to AX coordinates (the flip is its own inverse).
    var flippedToAX: CGRect { flippedToCocoa }
}

extension CGPoint {
    var flippedToAX: CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: height - y)
    }
}
