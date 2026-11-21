import AppKit
import CoreGraphics
import Foundation

struct MouseModeScheduledTask {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }

    static func scheduleOnMainRunLoop(
        interval: TimeInterval,
        repeats: Bool,
        operation: @escaping () -> Void
    ) -> MouseModeScheduledTask {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            operation()
        }
        RunLoop.main.add(timer, forMode: .common)
        return MouseModeScheduledTask { timer.invalidate() }
    }
}

/// 遥控器鼠标移动模式控制器（状态机 + 60Hz 平滑光标引擎）。
///
/// 由小米遥控器长按电源键（或配置的 `toggleMouseMode` 动作）切换进入/退出。
/// 激活期间接管方向键（平滑移动光标）与确认键（单击左键、长按右键）；
/// 其他按键保持原有绑定，且电源键短按仍可执行原有单击动作（默认 Esc），
/// 再次长按电源键退出鼠标模式。
final class MouseModeController {
    enum Phase: Equatable {
        case idle
        case active
    }

    static let tickInterval: TimeInterval = 1.0 / 60.0
    /// 单帧最大时间步长上限，防止主线程短暂卡顿时光标瞬移。
    static let maximumTickDelta: TimeInterval = 0.05
    /// 按下方向键瞬间立即前进的最小步长，确保极快点按也能精确微调。
    static let initialTapStep: Double = 4.0
    static let initialSpeed: Double = 180
    static let maximumSpeed: Double = 1400
    static let accelerationDuration: TimeInterval = 1.2
    static let defaultOKLongPressDuration: TimeInterval =
        Double(HIDRemoteTiming.longPressMilliseconds) / 1000
    static let doubleClickDistanceTolerance: Double = 5.0
    static let externalCursorSyncTolerance: Double = 2.5

    static let directionButtons: Set<RemoteButton> = [.up, .down, .left, .right]
    static let managedButtons: Set<RemoteButton> = directionButtons.union([.ok])

    typealias Scheduler = (TimeInterval, Bool, @escaping () -> Void) -> MouseModeScheduledTask
    typealias MovePoster = (CGPoint) -> Void
    typealias ClickPoster = (KeyboardInjector.MouseClickButton, CGPoint, Int64) -> Void

    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let postMove: MovePoster
    private let postClick: ClickPoster
    private let cursorPosition: () -> CGPoint?
    private let screenRects: () -> [CGRect]
    private let accessibilityTrusted: () -> Bool
    private let doubleClickInterval: () -> TimeInterval
    private let okLongPressDuration: TimeInterval
    private let logger: (String) -> Void

    private(set) var phase: Phase = .idle
    private var pressedDirections = Set<RemoteButton>()
    private var movementStartedAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    private var virtualCursorPosition: CGPoint?
    private var lastPostedCursorPosition: CGPoint?
    private var tickTask: MouseModeScheduledTask?
    private var okPressed = false
    private var okLongPressTask: MouseModeScheduledTask?
    private var okLongPressFired = false
    private var lastLeftClickAt: TimeInterval?
    private var lastLeftClickPosition: CGPoint?
    private var leftClickState: Int64 = 1

    var onStateChange: ((Bool) -> Void)?
    var isActive: Bool { phase == .active }

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = MouseModeScheduledTask.scheduleOnMainRunLoop,
        postMove: @escaping MovePoster = { KeyboardInjector.postMouseMoved(to: $0) },
        postClick: @escaping ClickPoster = { button, point, clickState in
            KeyboardInjector.postMouseClick(button: button, at: point, clickState: clickState)
        },
        cursorPosition: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
        screenRects: @escaping () -> [CGRect] = { MouseModeController.quartzScreenRects() },
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
        okLongPressDuration: TimeInterval = MouseModeController.defaultOKLongPressDuration,
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.now = now
        self.schedule = schedule
        self.postMove = postMove
        self.postClick = postClick
        self.cursorPosition = cursorPosition
        self.screenRects = screenRects
        self.accessibilityTrusted = accessibilityTrusted
        self.doubleClickInterval = doubleClickInterval
        self.okLongPressDuration = okLongPressDuration
        self.logger = logger
    }

    deinit {
        tickTask?.cancel()
        okLongPressTask?.cancel()
    }

    @discardableResult
    func activate() -> Bool {
        guard phase == .idle else { return true }
        guard accessibilityTrusted() else {
            logger("MOUSE MODE phase=rejected reason=accessibility_untrusted")
            return false
        }
        phase = .active
        virtualCursorPosition = cursorPosition()
        lastPostedCursorPosition = nil
        logger("MOUSE MODE phase=activated")
        onStateChange?(true)
        return true
    }

    func deactivate(reason: String = "manual") {
        guard phase == .active else { return }
        stopMovementLoop()
        okLongPressTask?.cancel()
        okLongPressTask = nil
        okPressed = false
        okLongPressFired = false
        pressedDirections.removeAll()
        virtualCursorPosition = nil
        lastPostedCursorPosition = nil
        lastLeftClickAt = nil
        lastLeftClickPosition = nil
        leftClickState = 1
        phase = .idle
        logger("MOUSE MODE phase=deactivated reason=\(reason)")
        onStateChange?(false)
    }

    @discardableResult
    func toggle() -> Bool {
        if phase == .active {
            deactivate(reason: "toggle_button")
            return true
        }
        return activate()
    }

    /// 当边缘事件被鼠标模式接管时返回 `true`，调用方应跳过普通手势识别与原生透传。
    @discardableResult
    func handle(button: RemoteButton, edge: RemoteEventEdge) -> Bool {
        guard phase == .active, Self.managedButtons.contains(button) else { return false }
        if edge == .down, !accessibilityTrusted() {
            deactivate(reason: "accessibility_revoked")
            return true
        }
        switch button {
        case .up, .down, .left, .right:
            switch edge {
            case .down:
                directionPressed(button)
            case .up:
                directionReleased(button)
            }
        case .ok:
            switch edge {
            case .down:
                okButtonPressed()
            case .up:
                okButtonReleased()
            }
        default:
            return false
        }
        return true
    }

    private func directionPressed(_ button: RemoteButton) {
        guard !pressedDirections.contains(button) else { return }
        let wasIdle = pressedDirections.isEmpty
        pressedDirections.insert(button)
        if wasIdle {
            let current = now()
            movementStartedAt = current
            lastTickAt = current
            syncVirtualCursorPositionFromSystem()
            applyMovementStep(distance: Self.initialTapStep)
            startMovementLoopIfNeeded()
        }
    }

    private func directionReleased(_ button: RemoteButton) {
        guard pressedDirections.remove(button) != nil else { return }
        if pressedDirections.isEmpty {
            stopMovementLoop()
        }
    }

    private func okButtonPressed() {
        guard !okPressed else { return }
        okPressed = true
        okLongPressFired = false
        okLongPressTask?.cancel()
        okLongPressTask = schedule(okLongPressDuration, false) { [weak self] in
            guard let self, self.phase == .active, self.okPressed else { return }
            self.okLongPressTask = nil
            guard self.accessibilityTrusted() else {
                self.deactivate(reason: "accessibility_revoked")
                return
            }
            self.okLongPressFired = true
            self.lastLeftClickAt = nil
            self.lastLeftClickPosition = nil
            self.leftClickState = 1
            if let position = self.resolvedClickPosition() {
                self.postClick(.right, position, 1)
                self.logger("MOUSE MODE click button=right trigger=long_press")
            }
        }
    }

    private func okButtonReleased() {
        guard okPressed else { return }
        okPressed = false
        okLongPressTask?.cancel()
        okLongPressTask = nil
        if okLongPressFired {
            okLongPressFired = false
            return
        }
        guard accessibilityTrusted() else {
            deactivate(reason: "accessibility_revoked")
            return
        }
        guard let position = resolvedClickPosition() else { return }
        let current = now()
        if let lastTime = lastLeftClickAt,
           let lastPosition = lastLeftClickPosition,
           current - lastTime <= doubleClickInterval(),
           hypot(position.x - lastPosition.x, position.y - lastPosition.y)
            <= Self.doubleClickDistanceTolerance {
            leftClickState += 1
        } else {
            leftClickState = 1
        }
        lastLeftClickAt = current
        lastLeftClickPosition = position
        postClick(.left, position, leftClickState)
        logger("MOUSE MODE click button=left click_state=\(leftClickState)")
    }

    private func startMovementLoopIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = schedule(Self.tickInterval, true) { [weak self] in
            self?.tick()
        }
    }

    private func stopMovementLoop() {
        tickTask?.cancel()
        tickTask = nil
        movementStartedAt = nil
        lastTickAt = nil
    }

    private func tick() {
        guard phase == .active else { return }
        guard accessibilityTrusted() else {
            deactivate(reason: "accessibility_revoked")
            return
        }
        guard !pressedDirections.isEmpty, let startedAt = movementStartedAt else {
            stopMovementLoop()
            return
        }
        let current = now()
        let elapsed = max(0, current - startedAt)
        let delta = min(
            lastTickAt.map { max(0, current - $0) } ?? Self.tickInterval,
            Self.maximumTickDelta
        )
        lastTickAt = current
        guard delta > 0 else { return }

        let distance = Self.speed(afterHoldingFor: elapsed) * delta
        applyMovementStep(distance: distance)
    }

    private func syncVirtualCursorPositionFromSystem() {
        guard let system = cursorPosition() else { return }
        if let lastPosted = lastPostedCursorPosition,
           let virtual = virtualCursorPosition,
           hypot(system.x - lastPosted.x, system.y - lastPosted.y)
            <= Self.externalCursorSyncTolerance {
            virtualCursorPosition = virtual
            return
        }
        virtualCursorPosition = system
    }

    private func resolvedClickPosition() -> CGPoint? {
        syncVirtualCursorPositionFromSystem()
        return virtualCursorPosition ?? cursorPosition()
    }

    private func applyMovementStep(distance: Double) {
        guard distance > 0 else { return }
        var axisX = 0.0
        var axisY = 0.0
        if pressedDirections.contains(.left) { axisX -= 1 }
        if pressedDirections.contains(.right) { axisX += 1 }
        // CGEvent 使用 Quartz 坐标系：向下为 +y。
        if pressedDirections.contains(.up) { axisY -= 1 }
        if pressedDirections.contains(.down) { axisY += 1 }
        let length = hypot(axisX, axisY)
        guard length > 0 else { return }

        syncVirtualCursorPositionFromSystem()
        guard let origin = virtualCursorPosition ?? cursorPosition() else { return }
        let rawTarget = CGPoint(
            x: origin.x + axisX / length * distance,
            y: origin.y + axisY / length * distance
        )
        let clamped = Self.clamped(rawTarget, from: origin, screens: screenRects())
        virtualCursorPosition = clamped
        lastPostedCursorPosition = clamped
        postMove(clamped)
    }

    /// 二次缓入加速：刚按下时 180 px/s 便于精确瞄准，1.2 秒后达到 1400 px/s 便于跨屏移动。
    static func speed(afterHoldingFor elapsed: TimeInterval) -> Double {
        let progress = min(max(elapsed / accelerationDuration, 0), 1)
        return initialSpeed + (maximumSpeed - initialSpeed) * progress * progress
    }

    static func clamped(
        _ target: CGPoint,
        from origin: CGPoint,
        screens: [CGRect]
    ) -> CGPoint {
        let validScreens = screens.filter { !$0.isNull && !$0.isEmpty && $0.width > 0 && $0.height > 0 }
        guard !validScreens.isEmpty else { return target }
        if validScreens.contains(where: { containsCursorPoint($0, point: target) }) {
            return target
        }
        let anchorScreen = validScreens.first(where: { containsCursorPoint($0, point: origin) })
            ?? validScreens.min {
                squaredDistance(from: origin, to: $0) < squaredDistance(from: origin, to: $1)
            }!
        let maxX = max(anchorScreen.minX, anchorScreen.maxX - 1)
        let maxY = max(anchorScreen.minY, anchorScreen.maxY - 1)
        return CGPoint(
            x: min(max(target.x, anchorScreen.minX), maxX),
            y: min(max(target.y, anchorScreen.minY), maxY)
        )
    }

    private static func containsCursorPoint(_ rect: CGRect, point: CGPoint) -> Bool {
        let maxX = max(rect.minX, rect.maxX - 1)
        let maxY = max(rect.minY, rect.maxY - 1)
        return point.x >= rect.minX && point.x <= maxX &&
            point.y >= rect.minY && point.y <= maxY
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let clampedX = min(max(point.x, rect.minX), max(rect.minX, rect.maxX - 1))
        let clampedY = min(max(point.y, rect.minY), max(rect.minY, rect.maxY - 1))
        let dx = Double(point.x - clampedX)
        let dy = Double(point.y - clampedY)
        return dx * dx + dy * dy
    }

    /// 将 NSScreen 的左下角原点坐标翻转为 Quartz 的左上角原点坐标。
    static func quartzScreenRects(screens: [NSScreen] = NSScreen.screens) -> [CGRect] {
        guard let primaryHeight = screens.first?.frame.height else { return [] }
        return screens.map { screen in
            let frame = screen.frame
            return CGRect(
                x: frame.origin.x,
                y: primaryHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
        }
    }
}

/// 鼠标移动模式切换时的非抢焦点屏幕顶部轻提示。
@MainActor
final class MouseModeBannerController {
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    func show(active: Bool, localization: LocalizationStore?) {
        guard let localization else { return }
        hideTask?.cancel()
        hideTask = nil

        let panel = ensurePanel()
        titleLabel.stringValue = localization.text(
            active ? "mouse_mode.hud.activated" : "mouse_mode.hud.deactivated"
        )
        detailLabel.stringValue = active
            ? localization.text("mouse_mode.hud.activated_detail")
            : ""
        detailLabel.isHidden = !active

        if let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let fitting = contentView.fittingSize
            let width = max(240, min(520, fitting.width + 36))
            let height = max(44, fitting.height + 24)
            let screen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main ?? NSScreen.screens.first
            let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let origin = NSPoint(
                x: frame.midX - width / 2,
                y: frame.maxY - height - 24
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let task = DispatchWorkItem { [weak self] in
            self?.hideImmediately()
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (active ? 2.2 : 1.2), execute: task)
    }

    func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -12),
        ])

        panel.contentView = visualEffect
        self.panel = panel
        return panel
    }
}
