// TouchAnywhere - entry point, event tap and menu.
//
// Sits in the menu bar and watches mouse events. When a remote-desktop client (Jump Desktop, AweSun/Sunlogin,
// RustDesk, VNC, ...) delivers a finger as plain mouse events, a one-finger swipe becomes a scroll, a tap stays a
// click, and press-and-hold-then-move stays a drag. Command-line helpers:
//   TouchAnywhere --selftest        run the decision-rule tests (touches nothing)
//   TouchAnywhere --scrolltest      pop up a test window and check scroll direction (and the whole pipeline if the app is running)
//   TouchAnywhere --dragtest        pop up a window and simulate a finger drag on its title bar (app must be running)
//   TouchAnywhere --snaptest        pop up a window and check that taps near the traffic-light buttons snap to them
//   TouchAnywhere --snap x y        read-only: where would a tap at this point land after snapping
//   TouchAnywhere --hit x y         read-only: is this point "scrollable", and what control is under it
//   TouchAnywhere --make-icon <dir> draw the app icon (used by build.sh)
import AppKit

let marker: Int64 = 0x54414E57     // events we post ourselves carry this tag so we never process them again

final class Runner {
    static var shared: Runner!
    let engine = TouchEngine()
    let d = UserDefaults.standard
    var tap: CFMachPort?
    private let src = CGEventSource(stateID: .hidSystemState)
    private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TouchAnywhere.log")
    private var logged = 0

    var enabled: Bool { d.object(forKey: "enabled") as? Bool ?? true }
    var remoteOnly: Bool { d.object(forKey: "remoteOnly") as? Bool ?? true }
    var snapRadius: Int { d.object(forKey: "snap") as? Int ?? 24 }
    var diagnose: Bool { d.object(forKey: "diagnose") as? Bool ?? true }

    init() {
        applyConfig()
        engine.wantsScroll = { HitTest.wantsScroll($0) }
        engine.retarget = { [weak self] p in
            guard let self = self else { return p }
            let q = HitTest.snap(p, radius: CGFloat(self.snapRadius))
            if q != p, self.diagnose { self.log("tap snapped (\(Int(p.x)),\(Int(p.y))) -> (\(Int(q.x)),\(Int(q.y)))") }
            return q
        }
        engine.emit = { [weak self] in self?.post($0) }
    }

    func applyConfig() {
        engine.cfg.holdSeconds = d.object(forKey: "hold") as? Double ?? 0.22
        engine.cfg.invert = d.bool(forKey: "invert")
        engine.cfg.inertia = d.object(forKey: "inertia") as? Bool ?? true
    }

    // MARK: 盯事件

    /// 权限没开时 tapCreate 会失败;开了以后不用重启,下一次重试就能成功
    func startTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        var mask: CGEventMask = 0
        for t in types { mask |= 1 << t.rawValue }
        let cb: CGEventTapCallBack = { _, type, ev, _ in Runner.shared.handle(type, ev) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: nil) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func handle(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(ev)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        if ev.getIntegerValueField(.eventSourceUserData) == marker { return pass }
        let pid = ev.getIntegerValueField(.eventSourceUnixProcessID)
        guard enabled else { return pass }
        // 没在处理一次手势时,只看远程来的(发送者不是硬件);手势进行中的后续事件一律接着处理
        if !engine.busy, remoteOnly, pid == 0 || pid == Int64(getpid()) { return pass }
        let p = ev.location
        let t = ProcessInfo.processInfo.systemUptime
        let cs = ev.getIntegerValueField(.mouseEventClickState)
        let mods = !ev.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
        var swallow = false
        switch type {
        case .leftMouseDown: swallow = engine.down(p, t: t, clickState: max(cs, 1), modifiers: mods)
        case .leftMouseDragged: swallow = engine.dragged(p, t: t)
        case .leftMouseUp: swallow = engine.up(p, t: t)
        default: break
        }
        if diagnose, type != .leftMouseDragged {
            log("\(type == .leftMouseDown ? "down" : "up  ") x=\(Int(p.x)) y=\(Int(p.y)) pid=\(pid) clicks=\(cs) modifiers=\(mods) reason: \(HitTest.lastReason) -> \(swallow ? "handled" : "passed through")")
        }
        return swallow ? nil : pass
    }

    // MARK: 补发

    func post(_ o: Out) {
        switch o {
        case let .mouse(type, p, cs):
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: cs)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        case let .scroll(dx, dy, p, phase, momentum):
            // 滚轮按指针当前位置投递,手指的按下被吞掉了,指针不一定在手指处:滑动一开始先挪过去
            if phase == 1 { CGWarpMouseCursorPosition(p) }
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    func log(_ line: String) {
        logged += 1
        if logged > 3000, let h = try? FileHandle(forWritingTo: logURL) { try? h.truncate(atOffset: 0); try? h.close(); logged = 0 }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        guard let data = "\(f.string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: logURL) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let r = Runner.shared!
    private var retry: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchAnywhere")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        if !r.startTap() {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.r.startTap() == true { t.invalidate() }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func note(_ t: String) { let it = NSMenuItem(title: t, action: nil, keyEquivalent: ""); it.isEnabled = false; menu.addItem(it) }
        func act(_ t: String, _ sel: Selector, on: Bool? = nil, tag: Int = 0, to: NSMenu? = nil) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self; it.tag = tag
            if let on = on { it.state = on ? .on : .off }
            (to ?? menu).addItem(it)
        }
        note(r.tap != nil ? T("Accessibility permission: granted, watching input", "辅助功能权限:已开,正在盯着") : T("Accessibility permission: not granted (takes effect as soon as you allow it)", "辅助功能权限:没开,开了就自动生效"))
        note(T("One-finger swipe = scroll · tap = click · press & hold, then move = drag", "单指滑动 = 滚动;轻点 = 点击;先按住再动 = 拖动"))
        note(T("Starting on a title bar, scrollbar, menu or window edge, or holding ⌘⌥⌃⇧, stays a normal drag", "起点在标题栏、滚动条、菜单、窗口边上,或按着 ⌘⌥⌃⇧ 时,保持普通拖动"))
        menu.addItem(.separator())
        act(T("Translate finger swipes", "翻译手指滑动"), #selector(toggleEnabled), on: r.enabled)
        act(T("Only remote input (leave the local mouse alone)", "只翻译远程控制来的(本机鼠标不动)"), #selector(toggleRemote), on: r.remoteOnly)
        act(T("Momentum after release", "松手后带惯性"), #selector(toggleInertia), on: r.engine.cfg.inertia)
        act(T("Reverse direction", "方向反过来"), #selector(toggleInvert), on: r.engine.cfg.invert)
        let holdItem = NSMenuItem(title: T("Scroll vs. drag (how long a still finger counts as drag)", "滑动还是拖动(手指停多久再动算拖动)"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, ms) in [(T("Favor dragging (0.15 s)", "更容易拖动(停 0.15 秒)"), 150), (T("Balanced (0.22 s)", "平衡(停 0.22 秒)"), 220), (T("Favor scrolling (0.35 s)", "偏向滑动(停 0.35 秒)"), 350)] {
            act(name, #selector(pickHold(_:)), on: Int((r.engine.cfg.holdSeconds * 1000).rounded()) == ms, tag: ms, to: sub)
        }
        holdItem.submenu = sub
        menu.addItem(holdItem)
        let snapItem = NSMenuItem(title: T("Tap snapping (a tap near a small button still hits it)", "点击吸附范围(点在小按钮旁边也算点中)"), action: nil, keyEquivalent: "")
        let snapSub = NSMenu()
        for (name, v) in [(T("Off", "关"), 0), (T("Small (14 pt)", "小 14 点"), 14), (T("Medium (24 pt)", "中 24 点"), 24), (T("Large (36 pt)", "大 36 点"), 36)] {
            act(name, #selector(pickSnap(_:)), on: r.snapRadius == v, tag: v, to: snapSub)
        }
        snapItem.submenu = snapSub
        menu.addItem(snapItem)
        act(T("Write diagnostic log (~/Library/Logs/TouchAnywhere.log)", "记诊断日志(~/Library/Logs/TouchAnywhere.log)"), #selector(toggleDiagnose), on: r.diagnose)
        menu.addItem(.separator())
        act(T("Open Accessibility settings", "打开 辅助功能 设置页"), #selector(openAccessibility))
        act(T("Quit TouchAnywhere", "退出 TouchAnywhere"), #selector(quit))
    }

    @objc private func toggleEnabled() { r.d.set(!r.enabled, forKey: "enabled") }
    @objc private func toggleRemote() { r.d.set(!r.remoteOnly, forKey: "remoteOnly") }
    @objc private func toggleInertia() { r.d.set(!r.engine.cfg.inertia, forKey: "inertia"); r.applyConfig() }
    @objc private func toggleInvert() { r.d.set(!r.engine.cfg.invert, forKey: "invert"); r.applyConfig() }
    @objc private func toggleDiagnose() { r.d.set(!r.diagnose, forKey: "diagnose") }
    @objc private func pickSnap(_ s: NSMenuItem) { r.d.set(s.tag, forKey: "snap") }
    @objc private func pickHold(_ s: NSMenuItem) { r.d.set(Double(s.tag) / 1000, forKey: "hold"); r.applyConfig() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

@main
enum Main {
    static func main() {
        let a = CommandLine.arguments
        if a.count >= 3, a[1] == "--make-icon" { exit(Tools.makeIcon(a[2])) }
        if a.count >= 2, a[1] == "--selftest" { exit(Tools.selftest()) }
        if a.count >= 2, a[1] == "--scrolltest" { exit(ScrollTest.run()) }
        if a.count >= 2, a[1] == "--dragtest" { exit(DragTest.run()) }
        if a.count >= 2, a[1] == "--snaptest" { exit(SnapTest.run()) }
        if a.count >= 4, a[1] == "--snap", let x = Double(a[2]), let y = Double(a[3]) {
            let p = CGPoint(x: x, y: y), q = HitTest.snap(p, radius: 24)
            print("point (\(Int(x)),\(Int(y))) -> \(q == p ? "no snapping, tap stays put" : "snaps to (\(Int(q.x)),\(Int(q.y)))")")
            exit(0)
        }
        if a.count >= 4, a[1] == "--hit", let x = Double(a[2]), let y = Double(a[3]) {
            let p = CGPoint(x: x, y: y)
            print("accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")  \(HitTest.wantsScroll(p) ? "scrollable" : "stays a normal drag")\n  controls: \(HitTest.chain(p))")
            exit(0)
        }
        let id = Bundle.main.bundleIdentifier ?? "io.github.touchanywhere"
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { exit(0) }
        Runner.shared = Runner()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum Tools {
    /// 不碰系统:把几种手势喂给判断规则,看吐出来的是不是该有的事件
    static func selftest() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ extra: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  " + extra))
            if !ok { fails += 1 }
        }
        func make(wants: Bool = true) -> (TouchEngine, () -> [Out]) {
            let e = TouchEngine()
            e.cfg.inertia = false
            e.wantsScroll = { _ in wants }
            var outs: [Out] = []
            e.emit = { outs.append($0) }
            return (e, { let o = outs; outs = []; return o })
        }
        let a = CGPoint(x: 100, y: 100)

        do { // 轻点
            let (e, take) = make()
            let s1 = e.down(a, t: 0, clickState: 1, modifiers: false)
            let s2 = e.up(a, t: 0.08)
            check("tap: original swallowed, press+release re-posted", s1 && s2 && take() == [.mouse(.leftMouseDown, a, 1), .mouse(.leftMouseUp, a, 1)])
        }
        do { // 双击的第二下带连击次数
            let (e, take) = make()
            _ = e.down(a, t: 0, clickState: 2, modifiers: false); _ = e.up(a, t: 0.05)
            check("double-click: second click keeps click count 2", take() == [.mouse(.leftMouseDown, a, 2), .mouse(.leftMouseUp, a, 2)])
        }
        do { // 单指向下滑
            let (e, take) = make()
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            let s1 = e.dragged(CGPoint(x: 100, y: 120), t: 0.05)
            let s2 = e.dragged(CGPoint(x: 100, y: 150), t: 0.10)
            let s3 = e.up(CGPoint(x: 100, y: 150), t: 0.12)
            let o = take()
            check("swipe: every event swallowed", s1 && s2 && s3)
            let want: [Out] = [
                .scroll(dx: 0, dy: 20, at: a, phase: 1, momentum: 0),
                .scroll(dx: 0, dy: 30, at: a, phase: 2, momentum: 0),
                .scroll(dx: 0, dy: 0, at: a, phase: 4, momentum: 0),
            ]
            check("swipe: finger down 20 then 30 pt = scroll +20 then +30, phases began > changed > ended", o == want, "\(o)")
        }
        do { // 横向滑
            let (e, take) = make()
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            _ = e.dragged(CGPoint(x: 70, y: 100), t: 0.05)
            check("horizontal swipe: finger left 30 pt = dx -30", take().first == .scroll(dx: -30, dy: 0, at: a, phase: 1, momentum: 0))
        }
        do { // 方向反过来
            let (e, take) = make()
            e.cfg.invert = true
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            _ = e.dragged(CGPoint(x: 100, y: 120), t: 0.05)
            check("reverse direction: +20 becomes -20", take().first == .scroll(dx: 0, dy: -20, at: a, phase: 1, momentum: 0))
        }
        do { // 先按住再动 = 拖动:整个拖动过程由我按顺序重发
            let (e, take) = make()
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            let b = CGPoint(x: 130, y: 100), c2 = CGPoint(x: 160, y: 100)
            let s1 = e.dragged(b, t: 0.6)
            let s2 = e.dragged(c2, t: 0.65)
            let s3 = e.up(c2, t: 0.7)
            check("hold then move: down, drag, drag, up re-posted in order", s1 && s2 && s3 && take() == [.mouse(.leftMouseDown, a, 1), .mouse(.leftMouseDragged, b, 1), .mouse(.leftMouseDragged, c2, 1), .mouse(.leftMouseUp, c2, 1)])
        }
        do { // 起点在标题栏等不可滑动处:动起来 = 普通拖动
            let (e, take) = make(wants: false)
            let s1 = e.down(a, t: 0, clickState: 1, modifiers: false)
            let b = CGPoint(x: 130, y: 100), c2 = CGPoint(x: 160, y: 100)
            let s2 = e.dragged(b, t: 0.05)
            let s3 = e.dragged(c2, t: 0.08)
            let s4 = e.up(c2, t: 0.1)
            check("title bar / scrollbar: movement = down, drag, drag, up re-posted in order", s1 && s2 && s3 && s4 && take() == [.mouse(.leftMouseDown, a, 1), .mouse(.leftMouseDragged, b, 1), .mouse(.leftMouseDragged, c2, 1), .mouse(.leftMouseUp, c2, 1)])
        }
        do { // 标题栏里轻点 = 点击
            let (e, take) = make(wants: false)
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            let s = e.up(a, t: 0.05)
            check("tap in a title bar: click re-posted", s && take() == [.mouse(.leftMouseDown, a, 1), .mouse(.leftMouseUp, a, 1)])
        }
        do { // 点击吸附:点击落在 retarget 给的位置
            let (e, take) = make(wants: false)
            let target = CGPoint(x: 90, y: 96)
            e.retarget = { _ in target }
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            _ = e.up(a, t: 0.05)
            check("tap snapping: click lands on the snapped position", take() == [.mouse(.leftMouseDown, target, 1), .mouse(.leftMouseUp, target, 1)])
        }
        do { // 吸附不影响滑动和长按拖动的起点
            let (e, take) = make()
            e.retarget = { _ in CGPoint(x: 1, y: 1) }
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            _ = e.dragged(CGPoint(x: 100, y: 120), t: 0.05)
            check("snapping does not affect swipes", take().first == .scroll(dx: 0, dy: 20, at: a, phase: 1, momentum: 0))
        }
        do { // leave-alone hook (extension point: positions another tool wants to handle itself)
            let (e, take) = make()
            e.leaveAlone = { _ in true }
            let s1 = e.down(a, t: 0, clickState: 1, modifiers: false)
            let s2 = e.dragged(CGPoint(x: 130, y: 100), t: 0.05)
            let s3 = e.up(CGPoint(x: 130, y: 100), t: 0.1)
            check("leave-alone hook: everything passed through", !s1 && !s2 && !s3 && take().isEmpty)
        }
        do { // 按着修饰键
            let (e, take) = make()
            let s1 = e.down(a, t: 0, clickState: 1, modifiers: true)
            let s2 = e.dragged(CGPoint(x: 130, y: 100), t: 0.05)
            check("modifier held: passed through", !s1 && !s2 && take().isEmpty)
        }
        do { // 抖一下不算动
            let (e, take) = make()
            _ = e.down(a, t: 0, clickState: 1, modifiers: false)
            let s = e.dragged(CGPoint(x: 103, y: 102), t: 0.04)
            _ = e.up(CGPoint(x: 103, y: 102), t: 0.08)
            check("finger jitter under 8 pt is still a tap", s && take() == [.mouse(.leftMouseDown, a, 1), .mouse(.leftMouseUp, a, 1)])
        }
        print(fails == 0 ? "all passed" : "\(fails) failed")
        return fails == 0 ? 0 : 1
    }

    /// 程序图标:绿色圆角方块上一只手
    static func makeIcon(_ dir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let px = pt * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let s = CGFloat(px)
            let path = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
            NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.55, alpha: 1),
                       ending: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.35, alpha: 1))?.draw(in: path, angle: -90)
            let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.4, weight: .medium).applying(.init(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let z = sym.size
                let k = min(s * 0.56 / z.width, s * 0.56 / z.height)
                sym.draw(in: NSRect(x: (s - z.width * k) / 2, y: (s - z.height * k) / 2, width: z.width * k, height: z.height * k))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: .png, properties: [:]) else { return 1 }
            try? data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
        }
        return 0
    }
}

/// 弹一个带长内容的小窗口,往里发滚轮事件,看内容往哪边走。只动自己的窗口
enum ScrollTest {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let tall = FlippedView(frame: NSRect(x: 0, y: 0, width: 1200, height: 3000))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        sv.documentView = tall
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        let w = NSWindow(contentRect: NSRect(x: 60, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = sv
        w.setFrameTopLeftPoint(NSPoint(x: 60, y: (NSScreen.screens.first?.frame.maxY ?? 900) - 120))
        w.orderFrontRegardless()
        // 窗口在屏幕上的位置(左上角原点坐标),窗口内容区中心
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let c = CGPoint(x: w.frame.midX, y: screenH - w.frame.midY)
        let clip = sv.contentView
        let runner = Runner()
        var result: Int32 = 0
        func report(_ name: String, _ ok: Bool, _ extra: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  " + extra))
            if !ok { result = 1 }
        }
        app.finishLaunching()
        func settle(_ sec: Double) {
            let end = Date().addingTimeInterval(sec)
            while Date() < end {
                if let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(e) }
            }
        }
        settle(0.5)
        clip.scroll(to: NSPoint(x: 300, y: 500)); sv.reflectScrolledClipView(clip); settle(0.2)
        // 1. 手指往下 40 点 → 内容往下走 → 看到更靠上的部分 → 可见区域原点 y 变小
        let y0 = clip.bounds.origin.y, x0 = clip.bounds.origin.x
        runner.post(.scroll(dx: 0, dy: 40, at: c, phase: 1, momentum: 0)); runner.post(.scroll(dx: 0, dy: 0, at: c, phase: 4, momentum: 0)); settle(0.4)
        let y1 = clip.bounds.origin.y
        report("posted scroll: finger down -> content moves down", y1 < y0, "y \(y0) → \(y1)")
        settle(0.3)
        runner.post(.scroll(dx: 20, dy: 0, at: c, phase: 1, momentum: 0)); settle(0.02)
        runner.post(.scroll(dx: 20, dy: 0, at: c, phase: 2, momentum: 0)); settle(0.02)
        runner.post(.scroll(dx: 0, dy: 0, at: c, phase: 4, momentum: 0)); settle(0.4)
        let x1 = clip.bounds.origin.x
        report("posted scroll: finger right -> content moves right", x1 < x0, "x \(x0) → \(x1)")
        // 2. 整条链路:模拟一次单指向下滑(需要本程序已在运行且有权限,否则只提示)
        let y2 = clip.bounds.origin.y
        let src = CGEventSource(stateID: .hidSystemState)
        func mouse(_ t: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        mouse(.leftMouseDown, c); settle(0.03)
        for i in 1...12 { mouse(.leftMouseDragged, CGPoint(x: c.x, y: c.y + CGFloat(i) * 6)); settle(0.016) }
        mouse(.leftMouseUp, CGPoint(x: c.x, y: c.y + 72)); settle(0.6)
        let y3 = clip.bounds.origin.y
        if y3 == y2 { print("full pipeline: no change (TouchAnywhere is not running, or Accessibility permission is missing)") }
        else { report("full pipeline: simulated one-finger swipe down -> content moves down", y3 < y2, "y \(y2) → \(y3)") }
        w.orderOut(nil)
        return result
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 弹一个带红黄绿按钮的小窗口,在按钮旁边不同距离"点"一下,看会不会吸到按钮中心
enum SnapTest {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: 60, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Snap test"
        w.setFrameTopLeftPoint(NSPoint(x: 60, y: (NSScreen.screens.first?.frame.maxY ?? 900) - 120))
        w.orderFrontRegardless()
        app.finishLaunching()
        let end = Date().addingTimeInterval(0.8)
        while Date() < end { if let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(e) } }
        guard let btn = w.standardWindowButton(.closeButton), let sup = btn.superview else { print("close button not found"); return 1 }
        let inWin = btn.convert(btn.bounds, to: nil)
        let onScreen = w.convertToScreen(inWin)
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let center = CGPoint(x: onScreen.midX, y: screenH - onScreen.midY)
        _ = sup
        print("close button centre at (\(Int(center.x)),\(Int(center.y))), size \(Int(onScreen.width))x\(Int(onScreen.height))")
        var fails = 0
        func probe(_ name: String, _ dx: CGFloat, _ dy: CGFloat, expectSnap: Bool) {
            let p = CGPoint(x: center.x + dx, y: center.y + dy)
            let q = HitTest.snap(p, radius: 24)
            let moved = q != p
            let ok = moved == expectSnap && (!moved || hypot(q.x - center.x, q.y - center.y) < 3)
            print((ok ? "PASS " : "FAIL ") + "\(name): tap (\(Int(p.x)),\(Int(p.y))) -> (\(Int(q.x)),\(Int(q.y)))\(moved ? " snapped to the button centre" : " stays put")")
            if !ok { fails += 1 }
        }
        probe("dead centre", 0, 0, expectSnap: false)         // 本来就点中,原地
        probe("10 pt above", 0, -10, expectSnap: true)
        probe("14 pt right (lands on the yellow button)", 14, 0, expectSnap: false)
        probe("14 pt left", -14, 0, expectSnap: true)
        probe("20 pt below (within the 24 pt radius)", 0, 20, expectSnap: true)
        probe("40 pt below (too far)", 0, 40, expectSnap: false)
        w.orderOut(nil)
        print(fails == 0 ? "all passed" : "\(fails) failed")
        return fails == 0 ? 0 : 1
    }
}

/// 弹一个窗口,模拟手指在标题栏按住拖动,每一步量窗口位置:应当平稳跟着手指走,开头不跳
enum DragTest {
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = NSWindow(contentRect: NSRect(x: 60, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Drag test"
        w.setFrameTopLeftPoint(NSPoint(x: 60, y: (NSScreen.screens.first?.frame.maxY ?? 900) - 120))
        w.orderFrontRegardless()
        app.finishLaunching()
        func settle(_ sec: Double) {
            let end = Date().addingTimeInterval(sec)
            while Date() < end { if let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(e) } }
        }
        settle(0.6)
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        func topLeft() -> CGPoint { CGPoint(x: w.frame.minX, y: screenH - w.frame.maxY) }
        let start = topLeft()
        let grab = CGPoint(x: start.x + 220, y: start.y + 14)     // 标题栏中间偏右,避开红黄绿按钮
        let src = CGEventSource(stateID: .hidSystemState)
        func mouse(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        mouse(.mouseMoved, grab); settle(0.1)
        mouse(.leftMouseDown, grab); settle(0.05)
        var worst: CGFloat = 0
        var trail: [String] = []
        for i in 1...16 {
            let p = CGPoint(x: grab.x + CGFloat(i) * 8, y: grab.y + CGFloat(i) * 4)
            mouse(.leftMouseDragged, p); settle(0.02)
            let moved = topLeft()
            let dx = moved.x - start.x, dy = moved.y - start.y
            trail.append("\(Int(dx)),\(Int(dy))")
            // 手指走了 (8i,4i);窗口应当落后不多(一两步以内),也不能超前
            worst = max(worst, abs(CGFloat(i) * 8 - dx))
        }
        mouse(.leftMouseUp, CGPoint(x: grab.x + 128, y: grab.y + 64)); settle(0.2)
        let end = topLeft()
        print("window offset after each step: \(trail.joined(separator: " "))")
        print("final offset (\(Int(end.x - start.x)),\(Int(end.y - start.y))), finger moved (128,64); largest lag \(Int(worst)) pt")
        w.orderOut(nil)
        let ok = abs(end.x - start.x - 128) <= 12 && abs(end.y - start.y - 64) <= 12
        print(ok ? "PASS window followed the finger all the way" : "FAIL window did not keep up")
        return ok ? 0 : 1
    }
}
