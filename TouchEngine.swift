// TouchAnywhere - the decision engine. It only decides what one finger-down means; it never touches the system itself.
//
// Rules (modelled on how an iPad driving a Mac via Sidecar feels):
//   * a finger-down is held back at first, to see how it moves;
//   * lifted without moving: a click is re-posted (at a "snapped" position if a small button is nearby);
//   * starts moving quickly: scroll-wheel events are posted, with momentum after release;
//   * rests longer than `holdSeconds`, then moves: a real drag (select text, move things), re-posted in order;
//   * starts in a "not scrollable" place (title bar, scrollbar, menu, window edge) or with a modifier key held:
//     taps still click, movement is a normal drag (moving a window).
import Foundation
import CoreGraphics

struct EngineConfig {
    var holdSeconds: Double = 0.22        // 落下后停多久再动,就算「要拖动」(而不是滑动)
    var moveThreshold: CGFloat = 8        // 在可滑动的地方,动超过这么远才算动了
    var dragThreshold: CGFloat = 5        // 在标题栏等「本来就是拖」的地方,动超过这么远就开始拖,别让窗口等太久
    var invert = false
    var inertia = true
}

enum Out: Equatable {
    case mouse(CGEventType, CGPoint, Int64)                       // 类型、位置、连击次数
    case scroll(dx: Int32, dy: Int32, at: CGPoint, phase: Int64, momentum: Int64)
}

final class TouchEngine {
    var cfg = EngineConfig()
    var emit: (Out) -> Void = { _ in }
    var wantsScroll: (CGPoint) -> Bool = { _ in true }
    var retarget: (CGPoint) -> CGPoint = { $0 }
    var leaveAlone: (CGPoint) -> Bool = { _ in false }     // 这个位置归别的程序自己处理(如另一个浮动工具的长按和拖动),全程放行

    private enum S { case idle, pending, pendingTap, scrolling, passing, dragging }
    private var s = S.idle
    private var start = CGPoint.zero, last = CGPoint.zero
    private var downTime = 0.0
    private var clickState: Int64 = 1
    private var rem = (x: 0.0, y: 0.0)
    private var samples: [(t: Double, dx: Double, dy: Double)] = []
    private var vx = 0.0, vy = 0.0
    private var timer: Timer?
    private var momentumStarted = false

    var busy: Bool { s != .idle }

    /// 返回 true = 这个事件吞掉,不要交给系统
    func down(_ p: CGPoint, t: Double, clickState cs: Int64, modifiers: Bool) -> Bool {
        stopMomentum()
        if modifiers || leaveAlone(p) { s = .passing; return false }
        s = wantsScroll(p) ? .pending : .pendingTap
        start = p; last = p; downTime = t; clickState = cs
        rem = (0, 0); samples = []
        return true
    }

    func dragged(_ p: CGPoint, t: Double) -> Bool {
        switch s {
        case .idle, .passing:
            return false
        case .pending:
            if hypot(p.x - start.x, p.y - start.y) < cfg.moveThreshold { return true }
            if t - downTime >= cfg.holdSeconds {
                // 先按住了一会儿:当拖动。补发按下,当前这个拖动也改成补发,保证先后顺序
                s = .dragging
                emit(.mouse(.leftMouseDown, start, clickState))
                emit(.mouse(.leftMouseDragged, p, clickState))
                return true
            }
            s = .scrolling
            slide(p, t: t, phase: 1)
            return true
        case .pendingTap:
            if hypot(p.x - start.x, p.y - start.y) < cfg.dragThreshold { return true }
            // 在标题栏等地方动起来了:普通拖动(拖窗口),补发按下和当前拖动,后面的放行
            s = .dragging
            emit(.mouse(.leftMouseDown, start, clickState))
            emit(.mouse(.leftMouseDragged, p, clickState))
            return true
        case .dragging:
            // 开始拖之后的每一下也由我按顺序重发,保证「按下」一定先于后面的拖动到达系统,窗口不会先跳一下
            emit(.mouse(.leftMouseDragged, p, clickState))
            return true
        case .scrolling:
            slide(p, t: t, phase: 2)
            return true
        }
    }

    func up(_ p: CGPoint, t: Double) -> Bool {
        defer { s = .idle }
        switch s {
        case .idle, .passing:
            return false
        case .dragging:
            emit(.mouse(.leftMouseUp, p, clickState))
            return true
        case .pending, .pendingTap:
            let q = retarget(start)
            emit(.mouse(.leftMouseDown, q, clickState))
            emit(.mouse(.leftMouseUp, q, clickState))
            return true
        case .scrolling:
            send(0, 0, phase: 4, momentum: 0)
            if cfg.inertia { startMomentum(releasedAt: t) }
            return true
        }
    }

    // MARK: 滑动

    private func slide(_ p: CGPoint, t: Double, phase: Int64) {
        let dx = Double(p.x - last.x), dy = Double(p.y - last.y)
        last = p
        samples.append((t, dx, dy))
        if samples.count > 12 { samples.removeFirst() }
        send(dx, dy, phase: phase, momentum: 0)
    }

    private func send(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64) {
        let k = cfg.invert ? -1.0 : 1.0
        rem.x += dx * k; rem.y += dy * k
        let ix = Int32(rem.x.rounded(.towardZero)), iy = Int32(rem.y.rounded(.towardZero))
        rem.x -= Double(ix); rem.y -= Double(iy)
        emit(.scroll(dx: ix, dy: iy, at: start, phase: phase, momentum: momentum))
    }

    // MARK: 惯性

    private func startMomentum(releasedAt t: Double) {
        guard let lastSample = samples.last, t - lastSample.t <= 0.1 else { return }   // 停了一下才松手就不滑了
        let recent = samples.filter { lastSample.t - $0.t <= 0.1 }
        let span = max(lastSample.t - (recent.first?.t ?? lastSample.t), 0.016)
        vx = recent.reduce(0) { $0 + $1.dx } / span
        vy = recent.reduce(0) { $0 + $1.dy } / span
        guard hypot(vx, vy) > 150 else { return }
        momentumStarted = false
        let tm = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepMomentum() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func stepMomentum() {
        vx *= 0.965; vy *= 0.965
        if hypot(vx, vy) < 30 { stopMomentum(); return }
        send(vx / 60, vy / 60, phase: 0, momentum: momentumStarted ? 2 : 1)
        momentumStarted = true
    }

    /// 手指再落下、或惯性自己滑完,都走这里
    func stopMomentum() {
        guard let tm = timer else { return }
        tm.invalidate(); timer = nil
        if momentumStarted { send(0, 0, phase: 0, momentum: 3) }
        momentumStarted = false
    }
}
