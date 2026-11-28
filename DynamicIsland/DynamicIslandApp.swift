/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import ApplicationServices
import Combine
import Defaults
import KeyboardShortcuts
import ServiceManagement
import Sparkle
import SwiftUI
import SkyLightWindow
import UserNotifications

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController
    /// Retained delegate instance that dynamically selects the Sparkle feed URL
    /// based on the user's update channel preference.
    private let updaterDelegate = AtollUpdaterDelegate()

    init() {
        // Skip Sparkle's launch-time update check during UI testing.
        // The AtollUpdaterDelegate overrides the feed URL at runtime
        // based on the user's selected update channel.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !AppRuntimeEnvironment.isUITesting,
            updaterDelegate: updaterDelegate, userDriverDelegate: nil)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {

            LayoutPicker()
            Divider()
            LaunchAtLoginToggle()
            Divider()
            CheckForUpdatesButton(updater: updaterController.updater)
            Button("Restart Z-island") {
                guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

                let workspace = NSWorkspace.shared

                if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
                {

                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true

                    workspace.openApplication(at: appURL, configuration: configuration)
                }

                NSApplication.shared.terminate(self)
            }
            Button("Quit Z-island", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        } label: {
            // 菜单栏图标：app 图标的 18pt 专用版本（MenuBarIcon，小尺寸单独绘制）
            Image(nsImage: MenuBarGlyph.image)
        }
    }
}

/// Menu-bar toggle that mirrors and controls the app's macOS login item
/// (System Settings › General › Login Items). Does not register anything
/// at launch — it only reflects the current SMAppService state.
struct LaunchAtLoginToggle: View {
    @State private var isLoginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval

    /// 以系统真实状态为准，注册/注销后立即反映到菜单的对号上。
    private func sync() {
        let status = SMAppService.mainApp.status
        isLoginItemEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isLoginItemEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Registration can fail (e.g. missing entitlement); fall
                    // back to whatever state the system actually reports.
                    NSLog("LaunchAtLogin toggle failed: \(error)")
                }
                sync()
            }
        )) {
            // 待用户到系统设置里允许时，别让对号再骗人，直接说清楚。
            Label(needsApproval ? "Launch at Login (waiting for approval)" : "Launch at Login", systemImage: "poweron")
        }
        .onAppear {
            // Re-sync with the system every time the menu opens, in case the
            // user toggled the login item from System Settings.
            sync()
        }
    }
}

/// 在默认布局与简约布局之间切换。
///
/// 两套布局的展开尺寸不同，而窗口尺寸只在开岛时算一次；所以岛上还开着时
/// 先把它收起，免得切换后停在上一个布局的尺寸上。
struct LayoutPicker: View {
    // 必须用 @Default 持有：只读 `Defaults[...]` 不会让视图订阅变化，
    // 菜单里的对号就会停在打开菜单时的旧值上。
    @Default(.enableMinimalisticUI) private var isMinimalistic

    private var layout: Binding<Bool> {
        Binding(
            get: { isMinimalistic },
            set: { newValue in
                // 避免重复写入触发一轮没必要的窗口重算。
                guard isMinimalistic != newValue else { return }
                if AppDelegate.shared?.vm.notchState == .open {
                    AppDelegate.shared?.vm.close()
                }
                isMinimalistic = newValue
            }
        )
    }

    var body: some View {
        Picker(selection: layout) {
            Text("Default Layout").tag(false)
            Text("Minimal Layout").tag(true)
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
        }
        .pickerStyle(.inline)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

extension AppDelegate {
    static var shared: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [NSScreen: NSWindow] = [:]
    var viewModels: [NSScreen: DynamicIslandViewModel] = [:]
    var window: NSWindow?
    let vm: DynamicIslandViewModel = .init()
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    var timer: Timer?
    let bluetoothAudioManager = BluetoothAudioManager.shared  // NEW: Bluetooth audio detection
    let idleAnimationManager = IdleAnimationManager.shared  // NEW: Custom idle animations
    var closeNotchWorkItem: DispatchWorkItem?
    private var previousScreens: [NSScreen]?
    private var cancellables = Set<AnyCancellable>()
    private var windowsHiddenForLock = false
    
    // Debouncing mechanism for window size updates
    private var windowSizeUpdateWorkItem: DispatchWorkItem?

//    var closeNotchWorkItem: DispatchWorkItem?
//    private var previousScreens: [NSScreen]?
//    private var cancellables = Set<AnyCancellable>()
//    
//    // Debouncing mechanism for window size updates
//    private var windowSizeUpdateWorkItem: DispatchWorkItem?
    
    private func debouncedUpdateWindowSize() {
        // Cancel any existing work item
        windowSizeUpdateWorkItem?.cancel()
        
        // Create new work item with delay
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateWindowSizeIfNeeded()
        }
        
        // Store reference and schedule
        windowSizeUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installTopMenuItemsIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = handleIncomingShelfURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleIncomingShelfURLs([URL(fileURLWithPath: filename)])
    }

    private func handleIncomingShelfURLs(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }

        Task { @MainActor [weak self] in
            let items = await ShelfDropService.items(from: fileURLs)
            guard !items.isEmpty else { return }

            ShelfStateViewModel.shared.add(items)
            self?.coordinator.currentView = .shelf
        }

        return true
    }
    

    func applicationWillTerminate(_ notification: Notification) {
        // Guarantee the native OSD is usable after we exit: if we were
        // suppressing it, OSDUIHelper is SIGSTOP-frozen and the async restore in
        // enableSystemHUD() would not finish before the process dies. Resume it
        // synchronously here so it is never left frozen. (See issue #568.)
        SystemOSDManager.resumeOSDUIHelperForTermination()

        // Cancel any pending window size updates
        windowSizeUpdateWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func onScreenLocked(_: Notification) {
        print("Screen locked")
        hideWindowsForLock()
    }

    @objc func onScreenUnlocked(_: Notification) {
        print("Screen unlocked")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.restoreWindowsAfterLock()
            self.adjustWindowPosition(changeAlpha: true)
        }
    }

    private func hideWindowsForLock() {
        guard !windowsHiddenForLock else { return }
        windowsHiddenForLock = true

        if Defaults[.showOnAllDisplays] {
            for window in windows.values {
                window.alphaValue = 0
                window.orderOut(nil)
            }
        } else if let window = window {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    private func restoreWindowsAfterLock() {
        guard windowsHiddenForLock else { return }
        windowsHiddenForLock = false

        if Defaults[.showOnAllDisplays] {
            for window in windows.values {
                window.orderFrontRegardless()
                window.alphaValue = 1
            }
        } else if let window = window {
            window.orderFrontRegardless()
            window.alphaValue = 1
        }
    }
    
    private func cleanupWindows(shouldInvert: Bool = false) {
        if shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays] {
            for (screen, window) in windows {
                // Tear down the hosted ContentView before dropping the window
                // (`.onDisappear` is unreliable for borderless panels).
                viewModels[screen]?.onViewTeardown?()
                viewModels[screen]?.onViewTeardown = nil
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
                window.close()
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            vm.onViewTeardown?()
            vm.onViewTeardown = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            window.close()
            self.window = nil
        }
    }

    /// Rebuilds the notch's CGSSpace membership from the live windows.
    /// This intentionally does not gate on `hideNotchOption == .never`: Space
    /// membership keeps the window anchored while switching desktops, while
    /// FullscreenMediaDetector/`hideOnClosed` owns whether the closed notch renders
    /// in fullscreen.
    @MainActor
    private func syncNotchSpaceMembership() {
        NotchSpaceManager.shared.notchSpace.windows = currentDynamicIslandWindows()
    }

    private func currentDynamicIslandWindows() -> Set<NSWindow> {
        if Defaults[.showOnAllDisplays] {
            return Set(windows.values)
        } else if let window = window {
            return [window]
        }
        return []
    }

    @MainActor
    private func reassertDynamicIslandWindowSpacePresence() {
        guard !windowsHiddenForLock else { return }

        syncNotchSpaceMembership()

        for window in currentDynamicIslandWindows() {
            window.collectionBehavior = DynamicIslandWindow.pinnedCollectionBehavior
            window.orderFrontRegardless()
        }
    }

    private func createDynamicIslandWindow(for screen: NSScreen, with viewModel: DynamicIslandViewModel)
        -> NSWindow
    {
        // Use the current required size instead of always using openNotchSize
        let baseSize = calculateRequiredNotchSize()
        let requiredSize = adjustedSizeForScreen(baseSize, screen: screen)
        let roundedWidth = requiredSize.width.rounded()
        let roundedHeight = requiredSize.height.rounded()
        
        let window = DynamicIslandWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: roundedWidth, height: roundedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.animationBehavior = .none
        // collectionBehavior is configured in DynamicIslandWindow.init

        window.contentView = FirstMouseHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                //.moveToSky()
        )
        
        NotchBridge.shared.viewModel = viewModel
        NotchBridge.shared.window = window
        let dropCatcher = NotchFileDropCatcher()
        dropCatcher.frame = NSRect(x: (window.frame.width - 260) / 2,
                                   y: window.frame.height - 44,
                                   width: 260,
                                   height: 44)
        dropCatcher.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        window.contentView?.addSubview(dropCatcher)

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)
        //SkyLightOperator.shared.delegateWindow(window)
        return window
    }

    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false)
    {
        if changeAlpha {
            window.alphaValue = 0
        }
        
        let screenFrame = screen.frame
        let topBleed = notchTopScreenBleed(for: screen.localizedName)
        let centerX = screenFrame.origin.x + (screenFrame.width / 2)
        let roundedWidth = window.frame.width.rounded()
        let roundedHeight = window.frame.height.rounded()
        let newX = (centerX - (roundedWidth / 2)).rounded()
        let newY = (screenFrame.maxY + topBleed - roundedHeight).rounded()

        window.setFrame(NSRect(
            x: newX,
            y: newY,
            width: roundedWidth,
            height: roundedHeight
        ), display: false)
        
        if changeAlpha {
            window.alphaValue = 1
        }
    }
    
    private func updateWindowSizeIfNeeded() {
        // Calculate required size based on current state
        let requiredSize = calculateRequiredNotchSize()
        let animateResize = shouldAnimateResize(for: requiredSize)
        resizeWindows(to: requiredSize, animated: animateResize, force: false)
    }

    private func updateWindowSizeForTabSwitch() {
        let requiredSize = calculateRequiredNotchSize()
        resizeWindows(to: requiredSize, animated: false, force: true)
    }
    
    private func calculateRequiredNotchSize() -> CGSize {
        // Check if inline sneak peek is showing and notch is closed
        let airPodsListeningModeSneakActive = vm.notchState == .closed &&
                                      coordinator.sneakPeek.show &&
                                      coordinator.sneakPeek.type == .bluetoothAudio &&
                                      coordinator.sneakPeek.value < 0 &&
                                      AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil
        let isInlineSneakPeekActive = vm.notchState == .closed && 
                                      Defaults[.enableSneakPeek] &&
                                      (
                                          coordinator.expandingView.show &&
                                          coordinator.expandingView.type == .music &&
                                          Defaults[.sneakPeekStyles] == .inline ||
                                          airPodsListeningModeSneakActive
                                      )
        
        // If inline sneak peek is active, use a wider width to accommodate the expanded content
        if isInlineSneakPeekActive {
            // Calculate required width for inline sneak peek:
            // Album art (~32) + Middle section (380) + Visualizer (~32) + horizontal padding (28) + clip shape margin (12)
            let inlineSneakPeekWidth: CGFloat = 460
            return CGSize(width: inlineSneakPeekWidth, height: vm.effectiveClosedNotchHeight)
        }
        // Use minimalistic or normal size based on settings
        var baseSize = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize(isDynamicIslandMode: shouldUseDynamicIslandMode(for: vm.screen)) : openNotchSize
        
        let result = addShadowPadding(
            to: baseSize,
            isMinimalistic: Defaults[.enableMinimalisticUI]
        )

        return result
    }
    /// Adds Dynamic Island shadow/top insets on non-notch screens, or top bleed on physical-notch screens.
    private func adjustedSizeForScreen(_ baseSize: CGSize, screen: NSScreen) -> CGSize {
        var adjusted = baseSize
        if shouldUseDynamicIslandMode(for: screen.localizedName) {
            adjusted.width += dynamicIslandShadowInset * 2
            adjusted.height += dynamicIslandTopOffset
        } else {
            adjusted.height += notchTopScreenBleed(for: screen.localizedName)
        }
        return adjusted
    }

    func ensureWindowSize(_ size: CGSize, animated: Bool, force: Bool = false) {
        resizeWindows(to: size, animated: animated, force: force)
    }

    private func resizeWindows(to size: CGSize, animated: Bool, force: Bool) {
        guard size.width > 0, size.height > 0 else { return }

        if Defaults[.showOnAllDisplays] {
            for (screen, window) in windows {
                let screenSize = adjustedSizeForScreen(size, screen: screen)
                if force || window.frame.size != screenSize {
                    resizeWindow(window, on: screen, to: screenSize, animated: animated)
                }
            }
        } else if let window {
            let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            let screenSize = adjustedSizeForScreen(size, screen: screen)
            if force || window.frame.size != screenSize {
                resizeWindow(window, on: screen, to: screenSize, animated: animated)
            }
        }
    }

    private func resizeWindow(_ window: NSWindow, on screen: NSScreen, to size: CGSize, animated: Bool) {
        let screenFrame = screen.frame
        let topBleed = notchTopScreenBleed(for: screen.localizedName)
        // Clamp width to screen width so the notch never extends beyond screen edges on scaled displays
        let clampedWidth = min(size.width, screenFrame.width).rounded()
        let maxHeight = screenFrame.height + topBleed
        let clampedHeight = min(size.height, maxHeight).rounded()
        let centerX = screenFrame.midX
        let newX = (centerX - (clampedWidth / 2)).rounded()
        let newY = (screenFrame.maxY + topBleed - clampedHeight).rounded()
        let targetFrame = NSRect(x: newX, y: newY, width: clampedWidth, height: clampedHeight)

        // `open()` intentionally requests a forced resize so every display is
        // considered, but an unchanged frame still needs no AppKit display
        // transaction. Avoiding that no-op matters during hover/click opens.
        guard window.frame != targetFrame else { return }

        // 窗口尺寸原本是瞬跳的（`animated` 参数被忽略），内容却在弹动画，
        // 两者质感对不上就显得生硬。这里让窗口边框也走同一条缓动曲线。
        guard animated else {
            window.setFrame(targetFrame, display: true)
            return
        }

        guard !NotchBridge.shared.isFileDragActive else {
            window.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    private func shouldAnimateResize(for newSize: CGSize) -> Bool {
        return true
    }
    
    /// 启动时“不急着做”的初始化，统一挪到首帧之后跑。
    ///
    /// 每一项都不影响窗口出现：动画资源是挂上岛以后才播的，应用图标改的是
    /// Finder 里那个图标，主菜单只在激活时才被打开，HUD 要等第一次按键，
    /// 剪贴板监控晚一个 runloop 开始也漏不掉东西。
    private func performDeferredLaunchSetup() {
        LockScreenManager.shared.configure(viewModel: vm)

        // Initialize idle animations (load bundled + built-in face)
        idleAnimationManager.initializeDefaultAnimations()

        applySelectedAppIcon()
        installTopMenuItemsIfNeeded()

        // Setup SystemHUD Manager
        SystemHUDManager.shared.setup(coordinator: coordinator)

        // Honour "Save History Across Restarts" before anything can read the
        // stored history back.
        ClipboardManager.purgeStoredHistoryIfPersistenceDisabled()

        // 剪贴板采集不再依赖头部那个图标（已移除），开着就随 app 启动。
        if Defaults[.enableClipboardManager], !ClipboardManager.shared.isMonitoring {
            ClipboardManager.shared.startMonitoring()
        }
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // 首帧只做“让岛出现”必需的事。
        //
        // 下面这些（动画资源、程序图标、主菜单、HUD 管路、剪贴板历史）没有一样
        // 影响窗口出现，但彩排时全挤在这里，把 didFinishLaunching 拖到 292ms。
        // 现在统一挪到首帧之后，用两次主队列轮转做保证（第一次里 SwiftUI
        // 提交首帧，第二次才轮到这些）。
        DispatchQueue.main.async {
            DispatchQueue.main.async { [weak self] in
                self?.performDeferredLaunchSetup()
            }
        }

        
        
        // Observe tab changes - use immediate resize to keep the notch pinned
        // Deferred to next run loop tick because @Published fires on willSet,
        // so coordinator.currentView still holds the OLD value at emission time.
        coordinator.$currentView.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateWindowSizeForTabSwitch()
            }
        }.store(in: &cancellables)


        Defaults.publisher(.openNotchWidth, options: []).sink { [weak self] _ in
            self?.debouncedUpdateWindowSize()
        }.store(in: &cancellables)

        Defaults.publisher(.enableShortcuts, options: []).sink { change in
            Task { @MainActor in
                KeyboardShortcuts.isEnabled = change.newValue
            }
        }.store(in: &cancellables)



        // The hide option changes fullscreen visibility, not Spaces pinning.
        // Re-sync in case the user changes it while macOS is moving Spaces.
        Defaults.publisher(.hideNotchOption, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncNotchSpaceMembership()
            }
        }.store(in: &cancellables)
        
        // Observe minimalistic UI setting changes - trigger window resize
        Defaults.publisher(.enableMinimalisticUI, options: []).sink { [weak self] _ in
            // Update window size IMMEDIATELY (no debouncing) to prevent position shift
            self?.updateWindowSizeIfNeeded()
        }.store(in: &cancellables)
        
        // Note: Polling setting removed - now uses event-driven private API detection only

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reassertDynamicIslandWindowSpacePresence()
                self?.adjustWindowPosition()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.adjustWindowPosition(changeAlpha: true)
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.adjustWindowPosition()
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            DispatchQueue.main.async {
                window.alphaValue =
                    self.coordinator.selectedScreen == self.coordinator.preferredScreen ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.cleanupWindows(shouldInvert: true)

            if !Defaults[.showOnAllDisplays] {
                // 拔外接屏、合盖那一瞬间 `screens` 可能是空的，别强解。
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
                let viewModel = self.vm
                let window = self.createDynamicIslandWindow(for: screen, with: viewModel)
                self.window = window
                self.adjustWindowPosition(changeAlpha: true)
            } else {
                self.adjustWindowPosition()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onScreenLocked(_:)),
            name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onScreenUnlocked(_:)),
            name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            guard Defaults[.enableShortcuts] else { return }

            self.coordinator.toggleSneakPeek(
                status: !self.coordinator.sneakPeek.show,
                type: .music,
                duration: 3.0
            )
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            guard let self = self else { return }
            guard Defaults[.enableShortcuts] else { return }

            let mouseLocation = NSEvent.mouseLocation

            var viewModel = self.vm

            if Defaults[.showOnAllDisplays] {
                for screen in NSScreen.screens {
                    if screen.frame.contains(mouseLocation) {
                        if let screenViewModel = self.viewModels[screen] {
                            viewModel = screenViewModel
                            break
                        }
                    }
                }
            }

            self.closeNotchWorkItem?.cancel()
            self.closeNotchWorkItem = nil

            switch viewModel.notchState {
            case .closed:
                viewModel.open()

                let workItem = DispatchWorkItem { [weak viewModel] in
                    viewModel?.close()
                }
                self.closeNotchWorkItem = workItem

                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
            case .open:
                viewModel.close()
            }
        }

        KeyboardShortcuts.isEnabled = Defaults[.enableShortcuts]

        if !Defaults[.showOnAllDisplays] {
            // 没有屏幕时（合盖、拔屏瞬间）跳过建窗，避免 `first!` 崩掉。
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let viewModel = self.vm
                let window = createDynamicIslandWindow(for: screen, with: viewModel)
                self.window = window
                adjustWindowPosition(changeAlpha: true)
            } else {
                adjustWindowPosition(changeAlpha: true)
            }
        } else {
            adjustWindowPosition(changeAlpha: true)
        }
        
        previousScreens = NSScreen.screens

    }

    private func installTopMenuItemsIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let insertionIndex = preferredMenuInsertionIndex(in: mainMenu)

        let accessibilityMenuItem = NSMenuItem(title: String(localized: "Accessibility"), action: nil, keyEquivalent: "")
        accessibilityMenuItem.identifier = NSUserInterfaceItemIdentifier("Atoll.Accessibility.Menu")
        let accessibilitySubmenu = NSMenu(title: String(localized: "Accessibility"))

        let requestAccessibility = NSMenuItem(
            title: String(localized: "Request Accessibility Access"),
            action: #selector(requestAccessibilityAccess),
            keyEquivalent: ""
        )
        requestAccessibility.target = self

        let openAccessibility = NSMenuItem(
            title: String(localized: "Open Accessibility Settings"),
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openAccessibility.target = self

        accessibilitySubmenu.addItem(requestAccessibility)
        accessibilitySubmenu.addItem(openAccessibility)
        accessibilityMenuItem.submenu = accessibilitySubmenu
        mainMenu.insertItem(accessibilityMenuItem, at: insertionIndex)

        let permissionsMenuItem = NSMenuItem(title: String(localized: "Permissions"), action: nil, keyEquivalent: "")
        permissionsMenuItem.identifier = NSUserInterfaceItemIdentifier("Atoll.Permissions.Menu")
        let permissionsSubmenu = NSMenu(title: String(localized: "Permissions"))

        let requestFullDisk = NSMenuItem(
            title: String(localized: "Request Full Disk Access"),
            action: #selector(requestFullDiskAccess),
            keyEquivalent: ""
        )
        requestFullDisk.target = self

        let openFullDisk = NSMenuItem(
            title: String(localized: "Open Full Disk Access Settings"),
            action: #selector(openFullDiskAccessSettings),
            keyEquivalent: ""
        )
        openFullDisk.target = self

        let openDevTools = NSMenuItem(
            title: String(localized: "Open Developer Tools Settings"),
            action: #selector(openDeveloperToolsSettingsFromMenu),
            keyEquivalent: ""
        )
        openDevTools.target = self

        permissionsSubmenu.addItem(requestFullDisk)
        permissionsSubmenu.addItem(openFullDisk)
        permissionsSubmenu.addItem(NSMenuItem.separator())
        permissionsSubmenu.addItem(openDevTools)
        permissionsMenuItem.submenu = permissionsSubmenu
        mainMenu.insertItem(permissionsMenuItem, at: insertionIndex + 1)

        let toolsMenuItem = NSMenuItem(title: String(localized: "Tools"), action: nil, keyEquivalent: "")
        toolsMenuItem.identifier = NSUserInterfaceItemIdentifier("Atoll.Tools.Menu")
        let toolsSubmenu = NSMenu(title: String(localized: "Tools"))

        let loggingLevelItem = NSMenuItem(title: String(localized: "Log Level"), action: nil, keyEquivalent: "")
        loggingLevelItem.identifier = NSUserInterfaceItemIdentifier("Atoll.Tools.LoggingLevel")
        let loggingLevelSubmenu = NSMenu(title: String(localized: "Log Level"))
        
        // Dispatched by tag, so the titles are safe to localize.
        let levels: [(String, LogLevel)] = [
            ("None", .none),
            ("Error", .error),
            ("Warning", .warning),
            ("Info", .info),
            ("Debug", .debug)
        ]
        
        for (title, level) in levels {
            let item = NSMenuItem(title: title, action: #selector(setLogLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level.rawValue
            item.state = (Defaults[.logLevel] == level) ? NSControl.StateValue.on : NSControl.StateValue.off
            loggingLevelSubmenu.addItem(item)
        }
        loggingLevelItem.submenu = loggingLevelSubmenu
        toolsSubmenu.addItem(loggingLevelItem)

        toolsSubmenu.addItem(NSMenuItem.separator())
        
        let exportLogsItem = NSMenuItem(title: String(localized: "Export Logs"), action: #selector(exportLogs), keyEquivalent: "")
        exportLogsItem.target = self
        toolsSubmenu.addItem(exportLogsItem)

        toolsMenuItem.submenu = toolsSubmenu
        mainMenu.insertItem(toolsMenuItem, at: insertionIndex + 2)

    }

    private func preferredMenuInsertionIndex(in mainMenu: NSMenu) -> Int {
        if let index = mainMenu.items.firstIndex(where: { $0.title == "Window" }) {
            return index
        }
        if let index = mainMenu.items.firstIndex(where: { $0.title == "Help" }) {
            return index
        }
        return max(mainMenu.numberOfItems, 0)
    }

    @objc private func requestAccessibilityAccess() {
        AccessibilityPermissionStore.shared.requestAuthorizationPrompt()
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermissionStore.shared.openSystemSettings()
    }

    @objc private func requestFullDiskAccess() {
        FullDiskAccessPermissionStore.shared.requestAccessPrompt()
    }

    @objc private func openFullDiskAccessSettings() {
        FullDiskAccessPermissionStore.shared.openSystemSettings()
    }

    @objc private func openDeveloperToolsSettingsFromMenu() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools",
            "x-apple.systempreferences:com.apple.preference.security"
        ]

        for candidate in urls {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func setLogLevel(_ sender: NSMenuItem) {
        guard let level = LogLevel(rawValue: sender.tag) else { return }
        Defaults[.logLevel] = level
        
        // Look these up by identifier: the titles are localized.
        guard let mainMenu = NSApp.mainMenu,
              let toolsItem = mainMenu.items.first(where: { $0.identifier?.rawValue == "Atoll.Tools.Menu" }),
              let toolsMenu = toolsItem.submenu,
              let loggingItem = toolsMenu.items.first(where: { $0.identifier?.rawValue == "Atoll.Tools.LoggingLevel" }),
              let loggingSubmenu = loggingItem.submenu else { return }
              
        for item in loggingSubmenu.items {
            item.state = (item.tag == level.rawValue) ? NSControl.StateValue.on : NSControl.StateValue.off
        }
    }

    @objc private func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "Z-island_Logs.zip"
        savePanel.title = "Export Logs & Crash Reports"
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            
            Task.detached(priority: .utility) {
                do {
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    let logsFile = tempDir.appendingPathComponent("app_logs.txt")
                    let logProcess = Process()
                    logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                    logProcess.arguments = ["show", "--predicate", "subsystem == 'com.zevin.zisland' OR subsystem == 'com.zevin.zisland.dev'", "--info", "--debug", "--last", "2d"]
                    
                    let pipe = Pipe()
                    logProcess.standardOutput = pipe
                    try logProcess.run()
                    logProcess.waitUntilExit()
                    
                    let logData = pipe.fileHandleForReading.readDataToEndOfFile()
                    try logData.write(to: logsFile)
                    
                    let diagDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
                    let allFiles = (try? FileManager.default.contentsOfDirectory(at: diagDir, includingPropertiesForKeys: nil)) ?? []
                    for file in allFiles where file.lastPathComponent.contains("Atoll") {
                        try? FileManager.default.copyItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
                    }
                    
                    let sysDiagDir = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
                    let sysFiles = (try? FileManager.default.contentsOfDirectory(at: sysDiagDir, includingPropertiesForKeys: nil)) ?? []
                    for file in sysFiles where file.lastPathComponent.contains("Atoll") {
                        try? FileManager.default.copyItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
                    }
                    
                    let zipProcess = Process()
                    zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    zipProcess.currentDirectoryURL = tempDir
                    let items = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
                    zipProcess.arguments = ["-r", url.path] + items
                    
                    try zipProcess.run()
                    zipProcess.waitUntilExit()
                    
                    try? FileManager.default.removeItem(at: tempDir)
                    
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Logs Exported")
                        alert.informativeText = String(localized: "Logs and crash reports have been successfully exported to \(url.lastPathComponent).")
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Export Failed")
                        alert.informativeText = String(localized: "Failed to export logs: \(error.localizedDescription)")
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
            }
        }
    }

    // Cancel the auto-close armed by `toggleNotchOpen`. Switching to the clipboard tab
    // from the header only changes `coordinator.currentView`, so without this the notch
    // can close mid-copy/drag a few seconds after it was opened.
    func cancelPendingNotchAutoClose() {
        closeNotchWorkItem?.cancel()
        closeNotchWorkItem = nil
    }

    // ⇧⌘V 打开剪贴板面板的全局快捷键已移除：它把 currentView 设成 .clipboard，
    // 而剪贴板在两种布局下都是岛内页签，没有对应的独立视图，按下去没有反应。
    // 相关注册代码一并清掉，避免看起来“有这个功能”。
    
    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }
    
    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.map { $0.localizedName })
                != Set(previousScreens?.map { $0.localizedName } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens
        
        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
            }
        }
    }
    
    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreens = Set(NSScreen.screens)
            
            for screen in windows.keys where !currentScreens.contains(screen) {
                if let window = windows[screen] {
                    viewModels[screen]?.onViewTeardown?()
                    viewModels[screen]?.onViewTeardown = nil
                    window.close()
                    windows.removeValue(forKey: screen)
                    viewModels.removeValue(forKey: screen)
                }
            }
            
            for screen in currentScreens {
                if windows[screen] == nil {
                    let viewModel = DynamicIslandViewModel(screen: screen.localizedName)
                    let window = createDynamicIslandWindow(for: screen, with: viewModel)
                    
                    windows[screen] = window
                    viewModels[screen] = viewModel
                }
                
                if let window = windows[screen], let viewModel = viewModels[screen] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)
                    
                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screens.first(where: {
                $0.localizedName == coordinator.preferredScreen
            }) {
                coordinator.selectedScreen = coordinator.preferredScreen
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main {
                coordinator.selectedScreen = mainScreen.localizedName
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }
            
            vm.screen = selectedScreen.localizedName
            vm.notchSize = getClosedNotchSize(screen: selectedScreen.localizedName)
            
            if window == nil {
                window = createDynamicIslandWindow(for: selectedScreen, with: vm)
            }
            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }

        syncNotchSpaceMembership()
    }
    
    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }
    
    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    
    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    
    
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}

// MARK: - 拖文件到刘海 → 自动展开暂存架

/// SwiftUI 的 DynamicIslandViewModel 没有单例，这里留一个弱引用给 AppKit 侧使用。
@MainActor
final class NotchBridge {
    static let shared = NotchBridge()
    weak var viewModel: DynamicIslandViewModel?
    /// 灵动岛窗口本身，用来做精确的"指针是否在岛上"判定。
    weak var window: NSWindow?
    /// 文件拖拽进行中：悬停轮询要让路，窗口也别播缓动（否则会跳一下）。
    var isFileDragActive = false
    private init() {}
}

/// 只覆盖刘海那一小块：拖文件进来时展开岛并切到暂存架，松手即入库。
@MainActor
final class NotchFileDropCatcher: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    // 点击刘海仍然要能展开，所以不透明于鼠标事件。
    override func mouseDown(with event: NSEvent) {
        NotchBridge.shared.viewModel?.open()
        DynamicIslandViewCoordinator.shared.currentView = DynamicIslandViewCoordinator.defaultOpenView
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// 收起时的命中框；拖拽开始后临时铺满整个面板。
    private var collapsedFrame: NSRect = .zero
    private var isExpandedForDrag = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        expandForDragIfNeeded()
        enterDragSession()
        return .copy
    }

    /// 岛一展开，可拖放区域就比刘海大得多；接收器必须同步铺满整个面板，
    /// 否则指针往下走会落到 SwiftUI 自己的区域，于是弹出主页面而不是暂存架。
    private func expandForDragIfNeeded() {
        guard !isExpandedForDrag, let superview else { return }
        collapsedFrame = frame
        isExpandedForDrag = true
        autoresizingMask = [.width, .height]
        frame = superview.bounds
    }

    private func collapseAfterDrag() {
        guard isExpandedForDrag else { return }
        isExpandedForDrag = false
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        if collapsedFrame != .zero {
            frame = collapsedFrame
        }
    }

    private func enterDragSession() {
        NotchBridge.shared.isFileDragActive = true
        NotchBridge.shared.viewModel?.open()
        // open() 内部会按设置重置页面，所以打开之后再切，并补一次延迟断言。
        DynamicIslandViewCoordinator.shared.currentView = .shelf
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard NotchBridge.shared.isFileDragActive else { return }
            DynamicIslandViewCoordinator.shared.currentView = .shelf
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDragSession()
    }

    private func endDragSession() {
        NotchBridge.shared.isFileDragActive = false
        collapseAfterDrag()
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        defer { endDragSession() }
        guard !urls.isEmpty else { return false }
        Task { @MainActor in
            let items = await ShelfDropService.items(from: urls)
            guard !items.isEmpty else { return }
            ShelfStateViewModel.shared.add(items)
            DynamicIslandViewCoordinator.shared.currentView = .shelf
            NotchBridge.shared.viewModel?.open()
        }
        return true
    }
}
