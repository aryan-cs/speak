// Auto Learn capture probe: runs Speak's real capture code (compiled from the app's sources)
// against a real paste into a chat box in a fresh Chrome, then optionally fixes a word by
// double-clicking and typing, presses Return, and prints the correction Speak would queue.
//
// The page is driven through Chrome DevTools only. Nothing here walks Chrome's accessibility
// tree, which would switch Chrome's accessibility on and hide bugs in how Speak does that.
//
// usage: probe <text-file> [--fix wrong=>right] [--send]
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
let args = CommandLine.arguments
let text = try String(contentsOfFile: args[1], encoding: .utf8)
let fix = args.firstIndex(of: "--fix").map { args[$0 + 1].components(separatedBy: "=>") }
let send = args.contains("--send")
let port = 9444

// MARK: DevTools

let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json")!)) as! [[String: Any]]
let page = pages.first { (($0["url"] as? String) ?? "").contains("composer.html") }!
let socket = URLSession.shared.webSocketTask(with: URL(string: page["webSocketDebuggerUrl"] as! String)!)
socket.resume()
var nextID = 1
func evaluate(_ expression: String) -> Any? {
    let result = devTools("Runtime.evaluate", ["expression": expression, "returnByValue": true])
    return (result?["result"] as? [String: Any])?["value"]
}
@discardableResult
func devTools(_ method: String, _ params: [String: Any]) -> [String: Any]? {
    let id = nextID; nextID += 1
    let message = try! JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
    let done = DispatchSemaphore(value: 0)
    socket.send(.string(String(decoding: message, as: UTF8.self))) { _ in done.signal() }
    done.wait()
    while true {
        var reply: String?
        socket.receive { if case .success(.string(let value)) = $0 { reply = value }; done.signal() }
        done.wait()
        guard let reply, let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], (object["id"] as? Int) == id else { continue }
        return object["result"] as? [String: Any]
    }
}
func screenPoint(_ js: String) -> CGPoint? {
    guard let v = evaluate("(() => { const r = \(js); if (!r) return null; const top = window.screenY + (window.outerHeight - window.innerHeight); return [window.screenX + r.left + r.width / 2, top + r.top + r.height / 2]; })()") as? [Double] else { return nil }
    return CGPoint(x: v[0], y: v[1])
}

// MARK: Input

let source = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] { let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap); pause(0.02) }
}
func type(_ string: String) {
    for character in string {
        let units = Array(String(character).utf16)
        for down in [true, false] { let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down); e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units); e?.post(tap: .cghidEventTap) }
        pause(0.05)
    }
}
func click(_ point: CGPoint, count: Int = 1) {
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    pause(0.05)
    for n in 1...count {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n)); e?.post(tap: .cghidEventTap)
        }
        pause(0.05)
    }
}

// MARK: Run

guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first(where: { app in
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "command=", "-p", "\(app.processIdentifier)"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("remote-debugging-port=\(port)")
}) else { print("test Chrome is not running"); exit(1) }
let pid = chrome.processIdentifier

_ = evaluate("__editor.commands.clearContent(true); true")
chrome.activate(); pause(0.6)
click(screenPoint("document.querySelector('.ProseMirror').getBoundingClientRect()")!)
pause(0.3)

let runtime = AutoLearnAXRuntime()
if args.contains("--dictation-start") {
    // Speak switches the app's web accessibility on when recording starts; then the user talks.
    let ready = DispatchSemaphore(value: 0)
    Task { await runtime.prepareWebAccessibility(processID: pid); ready.signal() }
    ready.wait()
    pause(2.0)
}

NSPasteboard.general.clearContents()
NSPasteboard.general.setString(text, forType: .string)
pause(0.1)
key(9, .maskCommand)  // Command-V, as Speak's CursorPaster does
let pastedAt = Date()

let done = DispatchSemaphore(value: 0)
Task {
    // Speak's capture schedule.
    var token: AutoLearnPasteToken?
    var elapsed: UInt64 = 0
    for (attempt, delay) in ([AutoLearnLimits.verificationDelayNanoseconds] + AutoLearnLimits.captureRetryDelaysNanoseconds).enumerated() {
        try? await Task.sleep(nanoseconds: delay); elapsed += delay
        switch await runtime.capturePastedText(text: text, processID: pid) {
        case .captured(let captured):
            token = captured
            print(String(format: "CAPTURED on attempt %d (%.0f ms after Command-V)", attempt + 1, Date().timeIntervalSince(pastedAt) * 1000))
        case .retryable(let reason, let detail):
            print("attempt \(attempt + 1): \(reason) \(detail)")
            continue
        case .rejected(let reason):
            print("REJECTED: \(reason)")
        }
        break
    }
    guard let token else {
        print("NOT CAPTURED"); await runtime.abandonCapture(processID: pid); done.signal(); return
    }

    if let fix, fix.count == 2 {
        // Double-click the misheard word and type the fix, as a person would.
        let word = fix[0].replacingOccurrences(of: "'", with: "\\'")
        let point = screenPoint("""
            (() => { const root = document.querySelector('.ProseMirror'); const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
              let node; while ((node = walker.nextNode())) { const i = node.data.indexOf('\(word)'); if (i >= 0) { const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + \(fix[0].utf16.count)); return r.getBoundingClientRect(); } } return null; })()
            """)
        if let point {
            if args.contains("--select-in-page") {
                // Select the word through the page, as a double-click would.
                _ = evaluate("""
                    (() => { const root = document.querySelector('.ProseMirror'); const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                      let node; while ((node = walker.nextNode())) { const i = node.data.indexOf('\(word)'); if (i >= 0) { const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + \(fix[0].utf16.count)); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); return true; } } return false; })()
                    """)
            } else {
                click(point, count: 2)
            }
            pause(0.4)
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            print("double-clicked at \(point); frontmost \(frontmost); selected: \((evaluate("window.getSelection().toString()") as? String).debugDescription)")
            if args.contains("--edit-in-page") {
                // Replace the word through the editor, which updates the box as an edit would.
                let replacement = fix[1].replacingOccurrences(of: "'", with: "\\'")
                let edited = evaluate("""
                    (() => { const s = __editor.state; let at = null;
                      s.doc.descendants((node, pos) => { if (at === null && node.isText) { const i = node.text.indexOf('\(word)'); if (i >= 0) at = pos + i; } });
                      if (at === null) return false;
                      return __editor.chain().focus().insertContentAt({ from: at, to: at + \(fix[0].count) }, '\(replacement)').run(); })()
                    """)
                print("editor edit returned: \(String(describing: edited))")
            } else if args.contains("--type-in-page") {
                devTools("Input.insertText", ["text": fix[1]])
            } else {
                type(fix[1])
            }
            pause(0.6)
            print("fixed '\(fix[0])' -> '\(fix[1])' by hand")
        } else { print("word '\(fix[0])' not found on the page") }
        print("box now: \((evaluate("__editor.getText()") as? String) ?? "?")")
        // Speak polls the field every 250 ms while it watches.
        for _ in 0..<4 {
            let observation = await runtime.observeField(token: token)
            print("  poll: \(observation.map { "\($0)" } ?? "no session")")
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    var finished = false
    if send {
        key(36)  // Return sends and clears the box.
        print("sent; box now \((evaluate("__editor.getText()") as? String)?.isEmpty == true ? "empty" : "not empty")")
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await runtime.observeField(token: token) == .detached { finished = true; print("Speak saw the paste leave the field"); break }
        }
        if !finished { print("Speak did NOT see the paste leave the field") }
    }
    let snapshot = await runtime.finishSnapshot(token: token)
    if let snapshot {
        print("snapshot baseline: \(snapshot.baselineFieldText.debugDescription)")
        print("snapshot final:    \(snapshot.finalFieldText.debugDescription)")
        print("pasted range \(snapshot.pastedRange) original: \(snapshot.originalPastedText.debugDescription)")
    } else { print("snapshot: none") }
    if let snapshot, let revision = FinalSnapshotDiffEngine.revision(from: snapshot) {
        let candidates = CorrectionDiffEngine.candidates(from: revision).filter { AutoLearnTextSimilarity.isCorrection(of: $0.originalText, to: $0.correctedText) }
        print("QUEUED: \(candidates.map { "'\($0.originalText)' -> '\($0.correctedText)'" })")
    } else {
        print("QUEUED: nothing")
    }
    done.signal()
}
done.wait()
