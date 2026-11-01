// TouchAnywhere - what is under the finger?
//
// A touch that lands in one of these places stays a normal drag (moving a window, dragging a scrollbar, resizing,
// using a menu): the top strip of a window (title bar + toolbar), a ring around the window edge, scrollbars, sliders,
// splitters, menus, the Dock, toolbars. If nothing can be read (app not responding, no Accessibility permission)
// the touch is treated as scrollable. Also finds small controls near a tap for "tap snapping".
import AppKit
import ApplicationServices

enum HitTest {
    private static let system = AXUIElementCreateSystemWide()
    private static let blockedRoles: Set<String> = [
        "AXScrollBar", "AXSlider", "AXSplitter", "AXGrowArea", "AXValueIndicator", "AXHandle", "AXIncrementor",
        "AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar", "AXDockItem",
    ]
    private static let blockedAncestors: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu"]
    static let titleStrip: CGFloat = 56     // 窗口顶上这一条按拖动算:标题栏加工具栏,拖窗口主要靠它
    static let edge: CGFloat = 8
    /// 最近一次判断的理由,给诊断日志用(不额外查询,不拖慢手感)
    static var lastReason = ""

    static func wantsScroll(_ p: CGPoint) -> Bool {
        AXUIElementSetMessagingTimeout(system, 0.15)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success, let hit = found else { lastReason = "unreadable, treated as scrollable"; return true }
        if let r = string(hit, kAXRoleAttribute), blockedRoles.contains(r) { lastReason = "control \(r)"; return false }
        // 先看靠近手指的几层里有没有工具栏、菜单(拖它们是操作,不是滚动)
        var cur = hit
        for _ in 0..<6 {
            if blockedAncestors.contains(string(cur, kAXRoleAttribute) ?? "") { lastReason = "inside a toolbar/menu"; return false }
            guard let parent = parent(cur) else { break }
            cur = parent
        }
        // 窗口直接问控件要,不一层层往上爬:网页类程序(Claude、ChatGPT、浏览器)里控件能套上百层
        guard let win = element(hit, kAXWindowAttribute), let pos = point(win, kAXPositionAttribute), let size = size(win, kAXSizeAttribute) else {
            lastReason = "no window"
            return false    // 没有窗口(桌面、程序坞之类),保持普通操作
        }
        let x = p.x - pos.x, y = p.y - pos.y
        if y < titleStrip { lastReason = "window top, \(Int(y)) pt down (drag-window zone)"; return false }
        if x < edge || x > size.width - edge || y > size.height - edge { lastReason = "window edge (resize zone)"; return false }
        lastReason = "window content (scrollable)"
        return true
    }

    // MARK: 点击吸附(手指点在小按钮旁边,也算点中它)

    private static let snapRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXMenuBarItem", "AXTab"]
    private static let noSnapRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXScrollBar", "AXMenuItem", "AXLink", "AXSecureTextField"]
    static let snapMaxSize: CGFloat = 48    // 只吸附小控件;大按钮本来就好点,网页大块链接也不吸

    /// 手指点在 p:p 下面已经是可点的控件、输入框之类,就原地不动;
    /// 否则在 radius 范围内找离得最近的小按钮,返回它的正中心。找不到、或查询太慢,返回 p
    static func snap(_ p: CGPoint, radius: CGFloat) -> CGPoint {
        guard radius > 0 else { return p }
        let t0 = ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(system, 0.05)
        if let hit = elementAt(p) {
            if clickable(hit) != nil || noSnapRoles.contains(string(hit, kAXRoleAttribute) ?? "") { return p }
        }
        var best: (d: CGFloat, c: CGPoint)?
        var r: CGFloat = 6
        while r <= radius {
            for k in 0..<8 {
                if ProcessInfo.processInfo.systemUptime - t0 > 0.12 { return best?.c ?? p }
                let a = Double(k) * Double.pi / 4
                let q = CGPoint(x: p.x + r * CGFloat(cos(a)), y: p.y + r * CGFloat(sin(a)))
                guard let hit = elementAt(q), let el = clickable(hit),
                      let pos = point(el, kAXPositionAttribute), let sz = size(el, kAXSizeAttribute),
                      sz.width <= snapMaxSize, sz.height <= snapMaxSize else { continue }
                let rect = CGRect(origin: pos, size: sz)
                let dx = max(rect.minX - p.x, 0, p.x - rect.maxX), dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
                let d = hypot(dx, dy)
                if d <= radius, best == nil || d < best!.d { best = (d, CGPoint(x: rect.midX, y: rect.midY)) }
            }
            if best != nil { break }
            r += 6
        }
        return best?.c ?? p
    }

    private static func elementAt(_ p: CGPoint) -> AXUIElement? {
        var found: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success ? found : nil
    }

    /// 控件自己或往上三层里,有没有可点的按钮类控件(按钮上的文字、图标被点到时,真正可点的是它的上一层)
    private static func clickable(_ e: AXUIElement) -> AXUIElement? {
        var cur = e
        for _ in 0..<4 {
            if snapRoles.contains(string(cur, kAXRoleAttribute) ?? "") { return cur }
            guard let par = parent(cur) else { return nil }
            cur = par
        }
        return nil
    }

    /// 给日志用:手指下面是什么
    static func describe(_ p: CGPoint) -> String {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success, let hit = found else { return "unreadable" }
        return string(hit, kAXRoleAttribute) ?? "?"
    }

    /// 给诊断用:从手指下面的控件一路往上的角色链,和窗口范围
    static func chain(_ p: CGPoint) -> String {
        var found: AXUIElement?
        let r = AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found)
        guard r == .success, let hit = found else { return "unreadable (error \(r.rawValue))" }
        var parts: [String] = []
        var cur = hit
        for _ in 0..<6 {
            parts.append(string(cur, kAXRoleAttribute) ?? "?")
            guard let par = parent(cur) else { break }
            cur = par
        }
        if let win = element(hit, kAXWindowAttribute) {
            parts.append("...window origin \(point(win, kAXPositionAttribute).map { "\($0)" } ?? "?") size \(size(win, kAXSizeAttribute).map { "\($0)" } ?? "?")")
        } else { parts.append("...no window found") }
        return parts.joined(separator: " ‹ ")
    }

    private static func string(_ e: AXUIElement, _ a: String) -> String? {
        AXUIElementSetMessagingTimeout(e, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private static func parent(_ e: AXUIElement) -> AXUIElement? { element(e, kAXParentAttribute) }
    private static func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(e, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v = v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func axValue(_ e: AXUIElement, _ a: String) -> AXValue? {
        AXUIElementSetMessagingTimeout(e, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v = v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
    private static func point(_ e: AXUIElement, _ a: String) -> CGPoint? {
        var p = CGPoint.zero
        guard let v = axValue(e, a), AXValueGetValue(v, .cgPoint, &p) else { return nil }
        return p
    }
    private static func size(_ e: AXUIElement, _ a: String) -> CGSize? {
        var s = CGSize.zero
        guard let v = axValue(e, a), AXValueGetValue(v, .cgSize, &s) else { return nil }
        return s
    }
}
