// AXProbe — compatibility spike for Echo (SPEC.md §11, milestone 0).
//
// Usage: axprobe [--delay 5] [--live 20] [--max-words 400] [--enhanced] [--screenshot] [--out DIR]
//
// After --delay seconds, inspects the focused text element of the frontmost app and reports
// whether Echo's needs are met: full text readable, visible range available, per-word screen
// bounds available and plausible. Then, for --live seconds, draws red boxes over every visible
// word (refreshed twice a second) and logs Accessibility notifications while you type and scroll.

import AppKit
import ApplicationServices

// MARK: - Options

struct Options {
    var delay = 5.0
    var live = 20.0
    var maxWords = 400
    var enhanced = false
    var screenshot = false
    var outDir = "results"
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--delay": o.delay = Double(args.next() ?? "") ?? o.delay
        case "--live": o.live = Double(args.next() ?? "") ?? o.live
        case "--max-words": o.maxWords = Int(args.next() ?? "") ?? o.maxWords
        case "--enhanced": o.enhanced = true
        case "--screenshot": o.screenshot = true
        case "--out": o.outDir = args.next() ?? o.outDir
        case "-h", "--help":
            print("axprobe [--delay 5] [--live 20] [--max-words 400] [--enhanced] [--screenshot] [--out DIR]")
            exit(0)
        default:
            print("Unknown option \(a)")
            exit(1)
        }
    }
    return o
}

// MARK: - Report

var reportLines: [String] = []

func log(_ s: String = "") {
    print(s)
    reportLines.append(s)
}

func ms(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - AX helpers

func attr(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return (e, v)
}

func param(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?
    let e = AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v)
    return (e, v)
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name).1 as? String
}

func int(_ el: AXUIElement, _ name: String) -> Int? {
    (attr(el, name).1 as? NSNumber)?.intValue
}

func axValue<T: BitwiseCopyable>(_ v: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = empty
    return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
}

func range(_ el: AXUIElement, _ name: String) -> CFRange? {
    axValue(attr(el, name).1, .cfRange, CFRange())
}

func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
    axValue(attr(el, name).1, .cgPoint, CGPoint.zero)
}

func size(_ el: AXUIElement, _ name: String) -> CGSize? {
    axValue(attr(el, name).1, .cgSize, CGSize.zero)
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
    return CGRect(origin: p, size: s)
}

func boundsFor(_ el: AXUIElement, _ r: CFRange) -> (AXError, CGRect?) {
    var r = r
    let arg = AXValueCreate(.cfRange, &r)!
    let (e, v) = param(el, kAXBoundsForRangeParameterizedAttribute, arg)
    return (e, axValue(v, .cgRect, CGRect.zero))
}

func rangeFor(_ el: AXUIElement, point p: CGPoint) -> CFRange? {
    var p = p
    let arg = AXValueCreate(.cgPoint, &p)!
    return axValue(param(el, kAXRangeForPositionParameterizedAttribute, arg).1, .cfRange, CFRange())
}

func stringFor(_ el: AXUIElement, _ r: CFRange) -> String? {
    var r = r
    let arg = AXValueCreate(.cfRange, &r)!
    return param(el, kAXStringForRangeParameterizedAttribute, arg).1 as? String
}

func names(_ el: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyAttributeNames(el, &n)
    return (n as? [String]) ?? []
}

func paramNames(_ el: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyParameterizedAttributeNames(el, &n)
    return (n as? [String]) ?? []
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute).1 as? [AXUIElement]) ?? []
}

func describe(_ el: AXUIElement) -> String {
    let role = str(el, kAXRoleAttribute) ?? "?"
    let sub = str(el, kAXSubroleAttribute).map { "/\($0)" } ?? ""
    let desc = str(el, kAXRoleDescriptionAttribute).map { " \"\($0)\"" } ?? ""
    return "\(role)\(sub)\(desc)"
}

func isTextElement(_ el: AXUIElement) -> Bool {
    if let n = int(el, kAXNumberOfCharactersAttribute), n > 0 { return true }
    if let v = str(el, kAXValueAttribute), !v.isEmpty,
       paramNames(el).contains(kAXBoundsForRangeParameterizedAttribute) { return true }
    return false
}

/// Breadth-first search below `root` for the largest element that looks like editable text.
func findTextDescendant(_ root: AXUIElement, maxNodes: Int = 20000, maxDepth: Int = 10) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    var best: (AXUIElement, Int)?
    while !queue.isEmpty && visited < maxNodes {
        let (el, depth) = queue.removeFirst()
        visited += 1
        if isTextElement(el) {
            let n = int(el, kAXNumberOfCharactersAttribute) ?? str(el, kAXValueAttribute)?.utf16.count ?? 0
            if best == nil || n > best!.1 { best = (el, n) }
        }
        if depth < maxDepth { queue += children(el).map { ($0, depth + 1) } }
    }
    return best?.0
}

// MARK: - Word geometry

struct WordBox {
    let range: CFRange
    let rect: CGRect?
    let error: AXError
}

let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}][\\p{L}\\p{M}'’\\-]*")

/// Returns the visible character range: AXVisibleCharacterRange if supported, otherwise an
/// estimate from AXRangeForPosition at the element's top-left and bottom-right corners.
func visibleRange(_ el: AXUIElement, totalLength: Int) -> (CFRange, String)? {
    if let r = range(el, kAXVisibleCharacterRangeAttribute), r.length > 0 {
        return (r, "AXVisibleCharacterRange")
    }
    guard let f = frame(el) else { return nil }
    let visibleFrame = f.intersection(screenUnionAX())
    guard !visibleFrame.isNull,
          let a = rangeFor(el, point: CGPoint(x: visibleFrame.minX + 2, y: visibleFrame.minY + 2)),
          let b = rangeFor(el, point: CGPoint(x: visibleFrame.maxX - 2, y: visibleFrame.maxY - 2)),
          b.location + b.length > a.location else { return nil }
    let end = min(totalLength, b.location + b.length)
    return (CFRange(location: a.location, length: end - a.location), "estimated via AXRangeForPosition")
}

func visibleText(_ el: AXUIElement, _ r: CFRange, fullText: String?) -> String? {
    if let s = stringFor(el, r) { return s }
    guard let full = fullText as NSString?, r.location + r.length <= full.length else { return nil }
    return full.substring(with: NSRange(location: r.location, length: r.length))
}

func wordBoxes(_ el: AXUIElement, visible: CFRange, text: String, maxWords: Int) -> ([WordBox], Double) {
    let ns = text as NSString
    let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(maxWords)
    let start = now()
    let boxes = matches.map { m -> WordBox in
        let r = CFRange(location: visible.location + m.range.location, length: m.range.length)
        let (e, rect) = boundsFor(el, r)
        return WordBox(range: r, rect: rect, error: e)
    }
    return (boxes, ms(start))
}

// MARK: - Screen coordinates (AX uses top-left origin of the primary screen)

func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

func screenUnionAX() -> CGRect {
    NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }.flipped(primaryHeight())
}

extension CGRect {
    /// Converts between AX (top-left origin) and Cocoa (bottom-left origin) global coordinates.
    func flipped(_ h: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: h - origin.y - height, width: width, height: height)
    }
}

// MARK: - Overlay

final class BoxView: NSView {
    var boxes: [CGRect] = []   // Cocoa global coordinates
    var screenOrigin = CGPoint.zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        for b in boxes {
            let local = b.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            let path = NSBezierPath(rect: local.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

final class Overlay {
    private var windows: [(NSWindow, BoxView)] = []

    init() {
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = BoxView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenOrigin = screen.frame.origin
            w.contentView = v
            w.orderFrontRegardless()
            windows.append((w, v))
        }
    }

    func show(_ axRects: [CGRect]) {
        let h = primaryHeight()
        let cocoa = axRects.map { $0.flipped(h) }
        for (w, v) in windows {
            v.boxes = cocoa.filter { $0.intersects(w.frame) }
            v.needsDisplay = true
            v.displayIfNeeded()
        }
    }

    func close() { windows.forEach { $0.0.orderOut(nil) } }
}

// MARK: - Notification observer

var notificationCounts: [String: Int] = [:]

let observerCallback: AXObserverCallback = { _, _, name, _ in
    notificationCounts[name as String, default: 0] += 1
}

func observe(pid: pid_t, app: AXUIElement, text: AXUIElement) -> AXObserver? {
    var obs: AXObserver?
    guard AXObserverCreate(pid, observerCallback, &obs) == .success, let obs else { return nil }
    var targets: [(AXUIElement, String, String)] = [
        (app, kAXFocusedUIElementChangedNotification, "app"),
        (app, kAXWindowMovedNotification, "app"),
        (app, kAXWindowResizedNotification, "app"),
        (text, kAXValueChangedNotification, "text"),
        (text, kAXSelectedTextChangedNotification, "text"),
    ]
    // Scrolling usually isn't reported on the text element itself; watch the enclosing scroll bar.
    var parent = attr(text, kAXParentAttribute).1 as! AXUIElement?
    for _ in 0..<6 {
        guard let p = parent else { break }
        if str(p, kAXRoleAttribute) == kAXScrollAreaRole {
            if let bar = attr(p, kAXVerticalScrollBarAttribute).1 as! AXUIElement? {
                targets.append((bar, kAXValueChangedNotification, "scrollbar"))
            }
            break
        }
        parent = attr(p, kAXParentAttribute).1 as! AXUIElement?
    }
    log("Notification registration:")
    for (el, n, label) in targets {
        let e = AXObserverAddNotification(obs, el, n as CFString, nil)
        log("  \(label).\(n): \(e == .success ? "ok" : "error \(e.rawValue)")")
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    return obs
}

// MARK: - Main

let opts = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("""
    Accessibility permission is not granted to the app running this tool (your terminal).
    Open System Settings › Privacy & Security › Accessibility, enable your terminal app, then run again.
    """)
    exit(2)
}

print("Switch to the target app and click inside the document text. Probing in \(Int(opts.delay))s…")
for i in stride(from: Int(opts.delay), to: 0, by: -1) {
    print("  \(i)…")
    Thread.sleep(forTimeInterval: 1)
}

guard let front = NSWorkspace.shared.frontmostApplication else { print("No frontmost app"); exit(1) }
let pid = front.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appEl, 3)

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
log("AXProbe report — \(stamp)")
log("App: \(front.localizedName ?? "?") (\(front.bundleIdentifier ?? "?")) version \((front.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }) ?? "?")")
log("Screens: \(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)x" }.joined(separator: ", "))")

if opts.enhanced {
    let e1 = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let e2 = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    log("Set AXEnhancedUserInterface: \(e1.rawValue), AXManualAccessibility: \(e2.rawValue)")
    Thread.sleep(forTimeInterval: 1)
}

let (focusErr, focusedRaw) = attr(appEl, kAXFocusedUIElementAttribute)
guard focusErr == .success, let focusedRaw else {
    log("FAIL: could not get focused element (AXError \(focusErr.rawValue))")
    exit(1)
}
let focused = focusedRaw as! AXUIElement
log("Focused element: \(describe(focused))")

var textEl = focused
if !isTextElement(focused) {
    log("Focused element has no text; searching descendants of the focused window…")
    let win = (attr(appEl, kAXFocusedWindowAttribute).1 as! AXUIElement?) ?? focused
    if let found = findTextDescendant(win) ?? findTextDescendant(focused) {
        textEl = found
        log("Found text element: \(describe(found))")
    } else {
        log("FAIL: no text element found under focused element or window")
    }
}

log()
log("== Element ==")
log("Role: \(describe(textEl))")
log("Frame (AX coords): \(frame(textEl).map { "\($0)" } ?? "unavailable")")
log("Attributes: \(names(textEl).joined(separator: ", "))")
log("Parameterized: \(paramNames(textEl).joined(separator: ", "))")
var settable: DarwinBoolean = false
AXUIElementIsAttributeSettable(textEl, kAXValueAttribute as CFString, &settable)
log("AXValue settable: \(settable.boolValue)")

log()
log("== Text ==")
let nChars = int(textEl, kAXNumberOfCharactersAttribute)
log("AXNumberOfCharacters: \(nChars.map(String.init) ?? "unavailable")")
var t = now()
let fullText = str(textEl, kAXValueAttribute)
let fullTextMs = ms(t)
if let fullText {
    let words = wordRegex.numberOfMatches(in: fullText, range: NSRange(location: 0, length: (fullText as NSString).length))
    log(String(format: "AXValue: %d UTF-16 chars, ~%d words, read in %.1f ms", (fullText as NSString).length, words, fullTextMs))
    log("Start: \(fullText.prefix(150).replacingOccurrences(of: "\n", with: "⏎"))")
} else {
    log("AXValue: unavailable as string (\(attr(textEl, kAXValueAttribute).0.rawValue))")
}
let totalLength = nChars ?? (fullText as NSString?)?.length ?? 0
log("Selected range: \(range(textEl, kAXSelectedTextRangeAttribute).map { "\($0.location)+\($0.length)" } ?? "unavailable")")

log()
log("== Visible range & word bounds ==")
let elFrame = frame(textEl)
var verdict: [String] = []
if let (vis, how) = visibleRange(textEl, totalLength: totalLength) {
    log("Visible range: \(vis.location)+\(vis.length) (\(how))")
    if let vt = visibleText(textEl, vis, fullText: fullText) {
        let (boxes, total) = wordBoxes(textEl, visible: vis, text: vt, maxWords: opts.maxWords)
        let ok = boxes.filter { $0.error == .success && $0.rect != nil && $0.rect!.width > 0 && $0.rect!.height > 0 }
        let errors = boxes.filter { $0.error != .success }
        let zero = boxes.count - ok.count - errors.count
        let outside = elFrame.map { f in ok.filter { !f.insetBy(dx: -4, dy: -4).intersects($0.rect!) }.count } ?? 0
        let ns = vt as NSString
        log("Words tested: \(boxes.count)")
        log("  bounds ok: \(ok.count), zero-size: \(zero), errors: \(errors.count), outside element frame: \(outside)")
        log(String(format: "  time: %.1f ms total, %.2f ms per word", total, boxes.isEmpty ? 0 : total / Double(boxes.count)))
        for b in boxes.prefix(8) {
            let w = ns.substring(with: NSRange(location: b.range.location - vis.location, length: b.range.length))
            log("  \"\(w)\" @\(b.range.location): \(b.rect.map { "\($0)" } ?? "error \(b.error.rawValue)")")
        }
        if let e = errors.first { log("  first error code: \(e.error.rawValue)") }
        if fullText == nil { verdict.append("Full text NOT readable via AXValue") }
        if ok.count == 0 { verdict.append("Word bounds NOT available → in-place highlighting impossible") }
        else if Double(ok.count) / Double(max(boxes.count, 1)) < 0.9 || outside > 0 {
            verdict.append("Word bounds PARTIAL/suspect → check the red boxes visually")
        } else {
            verdict.append("Word bounds available for all tested words → check alignment visually")
        }
    } else {
        log("Could not read visible text")
        verdict.append("Visible text NOT readable")
    }
} else {
    log("Visible range: unavailable (neither AXVisibleCharacterRange nor AXRangeForPosition worked)")
    verdict.append("Visible range NOT available")
}

log()
log("== Verdict (automatic) ==")
verdict.forEach { log("• \($0)") }

// Live phase: redraw boxes twice a second and count notifications while the user types/scrolls.
if opts.live > 0 {
    log()
    log("== Live phase (\(Int(opts.live))s) ==")
    let observer = observe(pid: pid, app: appEl, text: textEl)
    print(">>> Red boxes should sit exactly on each word. Now SCROLL, TYPE a few words, and RESIZE the window. <<<")
    let overlay = Overlay()
    var refreshTimes: [Double] = []
    var screenshotTaken = false
    let end = Date().addingTimeInterval(opts.live)
    while Date() < end {
        let t0 = now()
        var rects: [CGRect] = []
        var steps = ""
        let len = int(textEl, kAXNumberOfCharactersAttribute) ?? str(textEl, kAXValueAttribute)?.utf16.count ?? totalLength
        steps += String(format: "len %.0f", ms(t0))
        var t1 = now()
        if let (vis, _) = visibleRange(textEl, totalLength: len) {
            steps += String(format: ", range %.0f (%d+%d)", ms(t1), vis.location, vis.length)
            t1 = now()
            if let vt = stringFor(textEl, vis) ?? visibleText(textEl, vis, fullText: str(textEl, kAXValueAttribute)) {
                steps += String(format: ", text %.0f", ms(t1))
                t1 = now()
                rects = wordBoxes(textEl, visible: vis, text: vt, maxWords: opts.maxWords).0.compactMap(\.rect)
                steps += String(format: ", bounds %.0f (%d words)", ms(t1), rects.count)
            }
        }
        refreshTimes.append(ms(t0))
        log(String(format: "  refresh %5.0f ms: ", ms(t0)) + steps)
        overlay.show(rects)
        if opts.screenshot && !screenshotTaken {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let path = "\(opts.outDir)/\(front.bundleIdentifier ?? "app")-\(stamp).png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", path]
            try? p.run()
            p.waitUntilExit()
            log("Screenshot: \(path)")
            screenshotTaken = true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    overlay.close()
    _ = observer
    let sorted = refreshTimes.sorted()
    if !sorted.isEmpty {
        log(String(format: "Refresh (visible range + all word bounds): median %.1f ms, max %.1f ms over %d refreshes",
                   sorted[sorted.count / 2], sorted.last!, sorted.count))
    }
    log("Notifications received:")
    if notificationCounts.isEmpty { log("  none") }
    for (n, c) in notificationCounts.sorted(by: { $0.key < $1.key }) { log("  \(n): \(c)") }
}

try? FileManager.default.createDirectory(atPath: opts.outDir, withIntermediateDirectories: true)
let outPath = "\(opts.outDir)/\(front.bundleIdentifier ?? "app")-\(stamp).txt"
try? reportLines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
print("\nReport saved to \(outPath)")
