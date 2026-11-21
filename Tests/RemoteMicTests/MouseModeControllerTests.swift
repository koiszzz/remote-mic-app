import AppKit
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

private final class MouseModeTestHarness {
    struct ScheduledItem {
        let id: Int
        let interval: TimeInterval
        let repeats: Bool
        var nextFireAt: TimeInterval
        var cancelled = false
        let action: () -> Void
    }

    var currentTime: TimeInterval = 100.0
    var cursor = CGPoint(x: 500, y: 400)
    var screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    var trusted = true
    var doubleClickInterval: TimeInterval = 0.35
    var moves: [CGPoint] = []
    var clicks: [(button: KeyboardInjector.MouseClickButton, point: CGPoint, clickState: Int64)] = []
    var logs: [String] = []

    private var nextID = 1
    private var items: [ScheduledItem] = []

    lazy var controller: MouseModeController = {
        MouseModeController(
            now: { [unowned self] in self.currentTime },
            schedule: { [unowned self] interval, repeats, operation in
                self.scheduleItem(interval: interval, repeats: repeats, action: operation)
            },
            postMove: { [unowned self] point in
                self.cursor = point
                self.moves.append(point)
            },
            postClick: { [unowned self] button, point, clickState in
                self.clicks.append((button, point, clickState))
            },
            cursorPosition: { [unowned self] in self.cursor },
            screenRects: { [unowned self] in self.screens },
            accessibilityTrusted: { [unowned self] in self.trusted },
            doubleClickInterval: { [unowned self] in self.doubleClickInterval },
            okLongPressDuration: 0.55,
            logger: { [unowned self] in self.logs.append($0) }
        )
    }()

    var activeTaskCount: Int {
        items.filter { !$0.cancelled }.count
    }

    private func scheduleItem(
        interval: TimeInterval,
        repeats: Bool,
        action: @escaping () -> Void
    ) -> MouseModeScheduledTask {
        let id = nextID
        nextID += 1
        items.append(ScheduledItem(
            id: id,
            interval: interval,
            repeats: repeats,
            nextFireAt: currentTime + interval,
            action: action
        ))
        return MouseModeScheduledTask { [weak self] in
            guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[index].cancelled = true
        }
    }

    func advance(by duration: TimeInterval) {
        let target = currentTime + duration
        while true {
            var nextIndex: Int?
            var earliest = target + 0.000_001
            for index in items.indices where !items[index].cancelled {
                if items[index].nextFireAt <= earliest {
                    earliest = items[index].nextFireAt
                    nextIndex = index
                }
            }
            guard let index = nextIndex else { break }
            currentTime = items[index].nextFireAt
            let action = items[index].action
            if items[index].repeats {
                items[index].nextFireAt += items[index].interval
            } else {
                items[index].cancelled = true
            }
            action()
        }
        currentTime = target
    }
}

@MainActor
private final class MouseModeHIDTestScheduler: HIDRemoteScheduling {
    private final class Task: HIDRemoteScheduledTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private struct Entry {
        let task: Task
        var fireAt: UInt64
        let repeatInterval: UInt64?
        let action: () -> Void
    }

    private var nowMilliseconds: UInt64 = 0
    private var entries: [Entry] = []

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let task = Task()
        entries.append(Entry(
            task: task,
            fireAt: nowMilliseconds + afterMilliseconds,
            repeatInterval: repeatingEveryMilliseconds,
            action: action
        ))
        return task
    }

    func advance(by milliseconds: UInt64) {
        let target = nowMilliseconds + milliseconds
        while true {
            var nextIndex: Int?
            var earliest = target
            for index in entries.indices where !entries[index].task.cancelled {
                if entries[index].fireAt <= earliest {
                    earliest = entries[index].fireAt
                    nextIndex = index
                }
            }
            guard let index = nextIndex else { break }
            let entry = entries[index]
            nowMilliseconds = entry.fireAt
            if let repeatInterval = entry.repeatInterval {
                entries[index].fireAt += repeatInterval
            } else {
                entry.task.cancelled = true
            }
            entry.action()
        }
        nowMilliseconds = target
    }
}

@Suite("Mouse mode controller and Xiaomi power long-press")
struct MouseModeControllerTests {
    @Test func activationRequiresAccessibilityAndDeactivationClearsState() {
        let harness = MouseModeTestHarness()
        harness.trusted = false
        #expect(!harness.controller.activate())
        #expect(harness.controller.phase == .idle)

        harness.trusted = true
        #expect(harness.controller.activate())
        #expect(harness.controller.isActive)

        harness.controller.handle(button: .right, edge: .down)
        #expect(harness.activeTaskCount == 1)
        harness.controller.handle(button: .ok, edge: .down)
        #expect(harness.activeTaskCount == 2)

        harness.controller.deactivate(reason: "test")
        #expect(!harness.controller.isActive)
        #expect(harness.activeTaskCount == 0)
        #expect(harness.clicks.isEmpty)
    }

    @Test func arrowsMoveSmoothlyWithDiagonalNormalizationAndScreenClamping() {
        let harness = MouseModeTestHarness()
        #expect(harness.controller.activate())

        // 极短点按立即触发初始微调步长
        harness.controller.handle(button: .right, edge: .down)
        #expect(harness.cursor.x == 504)
        #expect(harness.cursor.y == 400)

        // 持续按住 1 秒会沿曲线加速移动
        harness.advance(by: 1.0)
        #expect(harness.cursor.x > 800)
        #expect(harness.cursor.y == 400)
        harness.controller.handle(button: .right, edge: .up)
        #expect(harness.activeTaskCount == 0)

        // 斜向移动：右 + 下速度矢量归一化
        harness.cursor = CGPoint(x: 500, y: 400)
        harness.controller.handle(button: .right, edge: .down)
        harness.controller.handle(button: .down, edge: .down)
        harness.advance(by: 0.5)
        harness.controller.handle(button: .right, edge: .up)
        harness.controller.handle(button: .down, edge: .up)
        let dx = harness.cursor.x - 504 // 首个 down 来自 .right 初始微调 4px
        let dy = harness.cursor.y - 400
        #expect(abs(dx - dy) < 1.0)
        #expect(dx > 50)

        // 对向按键互相抵消，不移动
        let beforeOpposite = harness.cursor
        harness.controller.handle(button: .left, edge: .down)
        harness.controller.handle(button: .right, edge: .down)
        let afterBothDown = harness.cursor
        harness.advance(by: 0.3)
        #expect(harness.cursor == afterBothDown)
        #expect(abs(afterBothDown.x - beforeOpposite.x) <= MouseModeController.initialTapStep)
        harness.controller.handle(button: .left, edge: .up)
        harness.controller.handle(button: .right, edge: .up)

        // 多屏幕边界：主屏 1920x1080 与右侧矮屏 [1920, 3200] x [200, 1080]
        harness.screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 200, width: 1280, height: 880),
        ]
        // 在 y=100 处向右移动不能跨入第二块屏幕上方空洞
        harness.cursor = CGPoint(x: 1915, y: 100)
        harness.controller.handle(button: .right, edge: .down)
        harness.advance(by: 0.5)
        harness.controller.handle(button: .right, edge: .up)
        #expect(harness.cursor.x == 1919)

        // 在 y=500 处可以顺利跨入第二块屏幕
        harness.cursor = CGPoint(x: 1915, y: 500)
        harness.controller.handle(button: .right, edge: .down)
        harness.advance(by: 0.5)
        harness.controller.handle(button: .right, edge: .up)
        #expect(harness.cursor.x > 1920)
    }

    @Test func okShortPressLeftClicksFastDoubleTapIncrementsClickStateAndLongPressRightClicks() {
        let harness = MouseModeTestHarness()
        #expect(harness.controller.activate())

        // 单击确认键：松开立即触发左键（无延迟）
        harness.controller.handle(button: .ok, edge: .down)
        harness.advance(by: 0.12)
        #expect(harness.clicks.isEmpty)
        harness.controller.handle(button: .ok, edge: .up)
        #expect(harness.clicks.count == 1)
        #expect(harness.clicks[0].button == .left)
        #expect(harness.clicks[0].clickState == 1)

        // 连续快速按第二次确认键：clickState 递增支持双击
        harness.advance(by: 0.1)
        harness.controller.handle(button: .ok, edge: .down)
        harness.advance(by: 0.08)
        harness.controller.handle(button: .ok, edge: .up)
        #expect(harness.clicks.count == 2)
        #expect(harness.clicks[1].button == .left)
        #expect(harness.clicks[1].clickState == 2)

        // 长按确认键达到 550ms：立即触发右键，随后松开不再补发左键
        harness.controller.handle(button: .ok, edge: .down)
        harness.advance(by: 0.54)
        #expect(harness.clicks.count == 2)
        harness.advance(by: 0.02)
        #expect(harness.clicks.count == 3)
        #expect(harness.clicks[2].button == .right)
        #expect(harness.clicks[2].clickState == 1)
        harness.controller.handle(button: .ok, edge: .up)
        #expect(harness.clicks.count == 3)
    }

    @Test @MainActor func xiaomiPowerLongPressTogglesMouseModeThroughHIDMonitor() throws {
        let suite = "MouseModeControllerTests.hid.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let profileID = try #require(settings.selectedRemoteProfileID)

        let scheduler = MouseModeHIDTestScheduler()
        let harness = MouseModeTestHarness()
        var performed: [(RemoteButton, ButtonTrigger, ButtonAction)] = []

        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { button, trigger, configured in
                performed.append((button, trigger, configured.action))
                return true
            },
            frontmostBundleIdentifier: { "com.example.test" },
            diagnosticLogger: { _ in }
        )
        harness.controller.onStateChange = { _ in
            monitor.flushInFlightInputState()
        }
        monitor.onInternalAction = { _, action in
            if action == .toggleMouseMode {
                _ = harness.controller.toggle()
            }
        }
        monitor.isMouseModeActive = { harness.controller.isActive }
        monitor.mouseModeEdgeHandler = { button, edge in
            harness.controller.handle(button: button, edge: edge)
        }
        monitor.onRemoteDisconnected = {
            harness.controller.deactivate(reason: "remote_disconnected")
        }

        #expect(monitor.connectSimulatedDevice(fingerprint: "xiaomi-mouse", profileID: profileID))

        let powerReport = Data([UInt8(RemoteButton.power.hidUsage), 0, 0, 0, 0, 0])
        let okReport = Data([UInt8(RemoteButton.ok.hidUsage), 0, 0, 0, 0, 0])
        let upReport = Data([UInt8(RemoteButton.up.hidUsage), 0, 0, 0, 0, 0])
        let homeReport = Data([UInt8(RemoteButton.home.hidUsage), 0, 0, 0, 0, 0])
        let releaseReport = Data(repeating: 0, count: 6)

        // 1. 短按电源键：触发默认 Esc，不进入鼠标模式
        monitor.handleSimulatedReport(reportID: 1, data: powerReport)
        scheduler.advance(by: 150)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        #expect(!harness.controller.isActive)
        #expect(performed.count == 1)
        #expect(performed[0].0 == .power && performed[0].1 == .singleClick && performed[0].2 == .escape)

        // 2. 长按电源键 >= 550ms：进入鼠标模式，松开不补发 Esc
        monitor.handleSimulatedReport(reportID: 1, data: powerReport)
        scheduler.advance(by: HIDRemoteTiming.longPressMilliseconds)
        #expect(harness.controller.isActive)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        #expect(performed.count == 1)

        // 3. 模式内按上键与确认键：走鼠标控制，不走普通按键动作
        let initialY = harness.cursor.y
        monitor.handleSimulatedReport(reportID: 1, data: upReport)
        #expect(harness.cursor.y < initialY)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)

        monitor.handleSimulatedReport(reportID: 1, data: okReport)
        scheduler.advance(by: 100)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        #expect(harness.clicks.count == 1)
        #expect(harness.clicks[0].button == .left)
        #expect(performed.count == 1)

        // 模式内按主页键：不受鼠标模式拦截，保持原动作
        monitor.handleSimulatedReport(reportID: 1, data: homeReport)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        #expect(performed.count == 2)
        #expect(performed[1].0 == .home && performed[1].2 == .showDesktop)

        // 4. 模式内再次长按电源键：退出鼠标模式
        monitor.handleSimulatedReport(reportID: 1, data: powerReport)
        scheduler.advance(by: HIDRemoteTiming.longPressMilliseconds)
        #expect(!harness.controller.isActive)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)

        // 5. 退出后确认键恢复原有动作（Enter）
        monitor.handleSimulatedReport(reportID: 1, data: okReport)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        #expect(performed.count == 3)
        #expect(performed[2].0 == .ok && performed[2].2 == .returnKey)

        // 6. 重进鼠标模式后断开连接：自动退出
        monitor.handleSimulatedReport(reportID: 1, data: powerReport)
        scheduler.advance(by: HIDRemoteTiming.longPressMilliseconds)
        #expect(harness.controller.isActive)
        monitor.handleSimulatedReport(reportID: 1, data: releaseReport)
        monitor.disconnectSimulatedDevice()
        #expect(!harness.controller.isActive)
    }

    @Test func statusItemPresentationReflectsMouseModeWithStreamingPriority() {
        #expect(StatusItemPresentation.resolve(
            physicalConnected: true,
            phoneConnected: false,
            watchConnected: false,
            webState: .disabled,
            isStreaming: false,
            isMouseModeActive: true
        ) == .mouseMode)

        #expect(StatusItemPresentation.resolve(
            physicalConnected: true,
            phoneConnected: false,
            watchConnected: false,
            webState: .disabled,
            isStreaming: true,
            isMouseModeActive: true
        ) == .streaming)
    }
}
