import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - 坐标与屏幕

func primaryScreen() -> NSScreen? { NSScreen.screens.first }
func primaryHeight() -> CGFloat { primaryScreen()?.frame.maxY ?? 0 }

func toCGPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight() - p.y) }
func toNSPoint(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight() - p.y) }

func displayID(_ s: NSScreen) -> CGDirectDisplayID {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func screenWith(id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { displayID($0) == id }
}

struct DockEdge {
    var side: String        // bottom / left / right
    var thickness: CGFloat
}

func dockInsets(_ s: NSScreen) -> (bottom: CGFloat, left: CGFloat, right: CGFloat) {
    (s.visibleFrame.minY - s.frame.minY,
     s.visibleFrame.minX - s.frame.minX,
     s.frame.maxX - s.visibleFrame.maxX)
}

/// Dock 的厚度：取所有屏幕里被 Dock 占掉的最大边距；都没有就按 75pt 估计。
func dockThickness() -> CGFloat {
    var t: CGFloat = 0
    for s in NSScreen.screens {
        let i = dockInsets(s)
        t = max(max(t, i.bottom), max(i.left, i.right))
    }
    return t > 0 ? t : 75
}

func dockEdge(of s: NSScreen) -> DockEdge {
    let i = dockInsets(s)
    if i.bottom >= i.left && i.bottom >= i.right && i.bottom > 0 {
        return DockEdge(side: "bottom", thickness: i.bottom)
    }
    if i.left >= i.right && i.left > 0 {
        return DockEdge(side: "left", thickness: i.left)
    }
    if i.right > 0 {
        return DockEdge(side: "right", thickness: i.right)
    }
    return DockEdge(side: "bottom", thickness: dockThickness())
}

/// Dock 现在停在哪个屏幕上（靠 visibleFrame 的边距判断，不需要任何权限）。
func dockScreen() -> NSScreen? {
    for s in NSScreen.screens {
        let i = dockInsets(s)
        if i.bottom > 1 || i.left > 1 || i.right > 1 { return s }
    }
    return nil
}

func targetDisplayID() -> CGDirectDisplayID {
    if let n = UserDefaults.standard.object(forKey: "targetDisplayID") as? NSNumber,
       screenWith(id: n.uint32Value) != nil {
        return n.uint32Value
    }
    return CGMainDisplayID()
}

// MARK: - 日志

func dlog(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(fmt.string(from: Date()))] \(msg)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/DockPin.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 事件回调

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    PinApp.shared.handleTap(type: type, event: event)
}

// MARK: - 主体

final class PinApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static let shared = PinApp()

    private var statusItem: NSStatusItem?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var permissionTimer: Timer?

    private var enabled: Bool = {
        if UserDefaults.standard.object(forKey: "pinEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "pinEnabled")
    }()

    private var targetID: CGDirectDisplayID = targetDisplayID()

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observeSystem()
        refreshPermission()
        dlog("launch trusted=\(AXIsProcessTrusted()) target=\(screenWith(id: targetID)?.localizedName ?? "?") dock=\(dockScreen()?.localizedName ?? "?")")
        if !AXIsProcessTrusted() {
            // 只主动弹一次，避免每次启动都打扰
            if !UserDefaults.standard.bool(forKey: "askedAX") {
                UserDefaults.standard.set(true, forKey: "askedAX")
                requestPermission()
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "DockPin")
        item.button?.toolTip = "DockPin — 把 Dock 锁在主屏"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: 权限 / 事件闸

    private func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func refreshPermission() {
        if AXIsProcessTrusted() {
            startTap()
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self, AXIsProcessTrusted() else { return }
                self.refreshPermission()
                self.rebuildMenu()
            }
        }
    }

    private func startTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: eventTapCallback,
                                        userInfo: nil) else {
            dlog("event tap create FAILED (trusted=\(AXIsProcessTrusted()))")
            return
        }
        dlog("event tap started")
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// 鼠标一进到「非目标屏」的 Dock 边缘带就吞掉这条 move 事件，
    /// Dock 就不会被招过来。按住 ⌥ 时放行，方便临时用别的屏。
    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        guard !NSEvent.modifierFlags.contains(.option) else { return Unmanaged.passUnretained(event) }

        let ns = toNSPoint(event.location)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(ns) }) else {
            return Unmanaged.passUnretained(event)
        }
        guard displayID(screen) != targetID else { return Unmanaged.passUnretained(event) }

        let edge = dockEdge(of: screen)
        let hit: Bool
        switch edge.side {
        case "left":  hit = ns.x - screen.frame.minX <= edge.thickness + 2
        case "right": hit = screen.frame.maxX - ns.x <= edge.thickness + 2
        default:      hit = ns.y - screen.frame.minY <= edge.thickness + 2
        }
        return hit ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: 拉回

    @objc func anchorNow(_ sender: Any?) {
        guard let t = screenWith(id: targetID) else { return }
        let saved = CGEvent(source: nil)?.location
        let edge = dockEdge(of: t)
        let p: NSPoint
        switch edge.side {
        case "left":  p = NSPoint(x: t.frame.minX + 2, y: t.frame.midY)
        case "right": p = NSPoint(x: t.frame.maxX - 2, y: t.frame.midY)
        default:      p = NSPoint(x: t.frame.midX, y: t.frame.minY + 2)
        }
        dlog("anchor -> \(t.localizedName) side=\(edge.side)")
        CGWarpMouseCursorPosition(toCGPoint(p))
        usleep(350_000)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    private func ensureOnTarget() {
        guard enabled, screenWith(id: targetID) != nil else { return }
        if let current = dockScreen(), displayID(current) != targetID {
            anchorNow(nil)
        }
    }

    // MARK: 系统事件

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWoke),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func systemWoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.ensureOnTarget()
        }
    }

    @objc private func screensChanged() {
        dlog("screen parameters changed: screens=\(NSScreen.screens.count)")
        // 显示器刚变化时 Dock 还在重排，等它稳定
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if screenWith(id: self.targetID) == nil { self.targetID = CGMainDisplayID() }
            self.ensureOnTarget()
            self.rebuildMenu()
        }
    }

    // MARK: 菜单

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let current = dockScreen()?.localizedName ?? "隐藏 / 未知"
        let target = screenWith(id: targetID)?.localizedName ?? "未知"

        let h1 = NSMenuItem(title: "Dock 当前在：\(current)", action: nil, keyEquivalent: "")
        h1.isEnabled = false
        menu.addItem(h1)

        let parent = NSMenuItem(title: "锁定到：\(target)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in NSScreen.screens {
            let it = NSMenuItem(title: s.localizedName, action: #selector(chooseTarget(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: displayID(s))
            it.state = displayID(s) == targetID ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        menu.addItem(parent)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "启用固定（按住 ⌥ 临时放行）", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let anchor = NSMenuItem(title: "立即把 Dock 拉回来", action: #selector(anchorNow(_:)), keyEquivalent: "")
        anchor.target = self
        menu.addItem(anchor)

        menu.addItem(.separator())

        if AXIsProcessTrusted() {
            let ok = NSMenuItem(title: "辅助功能权限：已授予", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            let need = NSMenuItem(title: "辅助功能权限：未授予（点此开启）", action: #selector(openAccessibility(_:)), keyEquivalent: "")
            need.target = self
            menu.addItem(need)
        }

        if enabled && tap == nil {
            let warn = NSMenuItem(title: "闸门未生效：等权限授予后自动启动", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DockPin", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "pinEnabled")
        rebuildMenu()
    }

    @objc private func chooseTarget(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        targetID = n.uint32Value
        UserDefaults.standard.set(n, forKey: "targetDisplayID")
        rebuildMenu()
    }

    @objc private func openAccessibility(_ sender: Any?) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - 命令行

func cliStatus() {
    print("DockPin 1.0 — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("辅助功能权限: \(AXIsProcessTrusted() ? "已授予" : "未授予")")
    let target = targetDisplayID()
    for (i, s) in NSScreen.screens.enumerated() {
        let ins = dockInsets(s)
        var tags: [String] = []
        if displayID(s) == CGMainDisplayID() { tags.append("primary") }
        if displayID(s) == target { tags.append("target") }
        print("  [\(i)] \(s.localizedName)  frame=\(s.frame)")
        print("       Dock 边距 bottom=\(Int(ins.bottom)) left=\(Int(ins.left)) right=\(Int(ins.right))  \(tags.joined(separator: ","))")
    }
    print("Dock 当前在: \(dockScreen()?.localizedName ?? "隐藏/未知")")
    print("锁定目标  : \(screenWith(id: target)?.localizedName ?? "未知")")
    print("Dock 厚度 : \(Int(dockThickness()))")
}

func cliSelftest() {
    let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
    let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                              options: .defaultTap, eventsOfInterest: mask,
                              callback: eventTapCallback, userInfo: nil)
    print("AX trusted: \(AXIsProcessTrusted())")
    print("event tap create: \(t == nil ? "FAILED" : "OK")")
    if let t { CFMachPortInvalidate(t) }
}

func cliAnchor() {
    let id = targetDisplayID()
    guard let t = screenWith(id: id) else { print("target screen not found"); return }
    let saved = CGEvent(source: nil)?.location
    let edge = dockEdge(of: t)
    let p: NSPoint
    switch edge.side {
    case "left":  p = NSPoint(x: t.frame.minX + 2, y: t.frame.midY)
    case "right": p = NSPoint(x: t.frame.maxX - 2, y: t.frame.midY)
    default:      p = NSPoint(x: t.frame.midX, y: t.frame.minY + 2)
    }
    CGWarpMouseCursorPosition(toCGPoint(p))
    usleep(350_000)
    if let saved { CGWarpMouseCursorPosition(saved) }
    print("anchored to \(t.localizedName); dock now on: \(dockScreen()?.localizedName ?? "?")")
}

let argv = CommandLine.arguments
if argv.contains("--status") { cliStatus(); exit(0) }
if argv.contains("--selftest") { cliSelftest(); exit(0) }
if argv.contains("--anchor") { cliAnchor(); exit(0) }

let app = NSApplication.shared
app.delegate = PinApp.shared
app.setActivationPolicy(.accessory)
app.run()
