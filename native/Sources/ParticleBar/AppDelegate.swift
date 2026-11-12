import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let analyzer = AudioAnalyzer()
    private let particles = ParticleField()
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()

    private var panels: [OverlayPanel] = []
    private var hosts: [NSHostingView<StripView>] = []
    private var statusItem: NSStatusItem!
    private var captureTask: Task<Void, Never>?
    private var didShowPermissionAlert = false

    private var currentSource: SourceID = .system

    private enum CaptureState {
        case starting
        case system
        case mic
        case demo
        case denied(String)
    }

    private var captureState: CaptureState = .starting

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        rebuildPanels()
        setupStatusItem()
        setupCallbacks()

        if CommandLine.arguments.contains("--check-visible") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { exit(1) }
                for panel in self.panels {
                    NSLog("[PB] check-visible frame=%@ visibleFlag=%d onScreen=%d",
                          NSStringFromRect(panel.frame),
                          panel.isVisible ? 1 : 0,
                          panel.occlusionState.contains(.visible) ? 1 : 0)
                }
                exit(0)
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--capture-live"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.captureLive(to: path)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        currentSource = settings.source
        restartSource()
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureTask?.cancel()
        micCapture.stop()
        Task { await systemCapture.stop() }
    }

    // MARK: - 窗口

    /// 每块屏幕一条：关掉旧窗口，按当前屏幕重新铺
    private func rebuildPanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        hosts.removeAll()

        for screen in NSScreen.screens {
            let panel = OverlayPanel()
            let view = StripView(analyzer: analyzer, particles: particles, palette: settings.palette)
            let host = NSHostingView(rootView: view)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.alphaValue = settings.opacity
            panel.ignoresMouseEvents = settings.clickThrough

            let frame = NSRect(
                x: screen.frame.minX,
                y: screen.visibleFrame.maxY - settings.height,
                width: screen.frame.width,
                height: settings.height
            )
            panel.setFrame(frame, display: true)
            host.frame = NSRect(origin: .zero, size: frame.size)
            panel.orderFrontRegardless()

            panels.append(panel)
            hosts.append(host)
        }
    }

    /// 调试用：把实时 NSHostingView 的内容存成 PNG，不依赖屏幕录制权限
    private func captureLive(to path: String) {
        guard let view = hosts.first,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("[PB] capture-live: 无法创建位图")
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("[PB] capture-live: 无法编码 PNG")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("[PB] capture-live: 已写入 %@", path)
        } catch {
            NSLog("[PB] capture-live: 写入失败 %@", error.localizedDescription)
        }
        exit(0)
    }

    private func applyLayout() {
        guard panels.count == NSScreen.screens.count else {
            rebuildPanels()
            return
        }
        let height = settings.height
        for (panel, screen) in zip(panels, NSScreen.screens) {
            let frame = NSRect(
                x: screen.frame.minX,
                y: screen.visibleFrame.maxY - height,
                width: screen.frame.width,
                height: height
            )
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        }
    }

    @objc private func screenParametersChanged() {
        rebuildPanels()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "粒子音乐条")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "粒子音乐条", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let anyVisible = panels.contains { $0.isVisible }
        let visible = NSMenuItem(
            title: anyVisible ? "隐藏光条" : "显示光条",
            action: #selector(toggleVisible),
            keyEquivalent: ""
        )
        visible.target = self
        menu.addItem(visible)

        menu.addItem(sourceMenu())
        menu.addItem(paletteMenu())
        menu.addItem(heightMenu())
        menu.addItem(opacityMenu())

        let clickThrough = NSMenuItem(title: "鼠标穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThrough.target = self
        clickThrough.state = settings.clickThrough ? .on : .off
        menu.addItem(clickThrough)

        menu.addItem(.separator())

        let reconnect = NSMenuItem(title: "重新连接音频", action: #selector(reconnect), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)

        let permissions = NSMenuItem(title: "打开屏幕录制权限设置…", action: #selector(openScreenSettings), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var statusText: String {
        switch captureState {
        case .starting:
            return "正在连接音频…"
        case .system:
            return "正在跟随系统声音"
        case .mic:
            return "正在跟随麦克风"
        case .demo:
            return "演示信号（未连接真实音频）"
        case .denied(let message):
            return "未连接：" + message
        }
    }

    private func sourceMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for source in SourceID.allCases {
            let item = NSMenuItem(title: source.title, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = currentSource == source ? .on : .off
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: "音源", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func paletteMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for palette in PaletteID.allCases {
            let item = NSMenuItem(title: palette.title, action: #selector(selectPalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = palette.rawValue
            item.state = settings.palette == palette ? .on : .off
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func heightMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for height in [80, 110, 140] as [CGFloat] {
            let item = NSMenuItem(title: "\(Int(height)) pt", action: #selector(selectHeight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(height)
            item.state = abs(settings.height - height) < 1 ? .on : .off
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: "高度", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func opacityMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for value in [0.55, 0.75, 0.9, 1.0] {
            let item = NSMenuItem(
                title: "\(Int(value * 100))%",
                action: #selector(selectOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = abs(settings.opacity - value) < 0.01 ? .on : .off
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    // MARK: - 动作

    @objc private func toggleVisible() {
        let anyVisible = panels.contains { $0.isVisible }
        for panel in panels {
            if anyVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    @objc private func toggleClickThrough() {
        settings.clickThrough.toggle()
        for panel in panels {
            panel.ignoresMouseEvents = settings.clickThrough
        }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = SourceID(rawValue: raw) else { return }
        currentSource = source
        settings.source = source
        restartSource()
    }

    @objc private func selectPalette(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let palette = PaletteID(rawValue: raw) else { return }
        settings.palette = palette
        for host in hosts {
            host.rootView = StripView(analyzer: analyzer, particles: particles, palette: palette)
        }
    }

    @objc private func selectHeight(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        settings.height = CGFloat(value)
        applyLayout()
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        settings.opacity = value
        for panel in panels {
            panel.alphaValue = value
        }
    }

    @objc private func reconnect() {
        restartSource()
    }

    @objc private func openScreenSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 采集

    private func setupCallbacks() {
        systemCapture.onAudio = { [weak self] mono, rate in
            self?.analyzer.push(mono, sampleRate: rate)
        }
        systemCapture.onError = { [weak self] error in
            DispatchQueue.main.async { self?.handleCaptureError(error) }
        }
        micCapture.onAudio = { [weak self] mono, rate in
            self?.analyzer.push(mono, sampleRate: rate)
        }
        micCapture.onError = { [weak self] error in
            DispatchQueue.main.async { self?.handleCaptureError(error) }
        }
    }

    private func restartSource() {
        captureTask?.cancel()
        analyzer.demoMode = false
        captureState = .starting
        refreshStatusIcon()

        let source = currentSource
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.systemCapture.stop()
            self.micCapture.stop()
            if Task.isCancelled { return }

            switch source {
            case .demo:
                await MainActor.run {
                    self.analyzer.demoMode = true
                    self.captureState = .demo
                    self.refreshStatusIcon()
                }
            case .system:
                do {
                    try await self.systemCapture.start()
                    await MainActor.run {
                        self.captureState = .system
                        self.refreshStatusIcon()
                    }
                } catch {
                    await MainActor.run { self.handleCaptureError(error) }
                }
            case .mic:
                let granted = await MicCapture.requestPermission()
                guard granted else {
                    await MainActor.run { self.handleCaptureError(CaptureError.micDenied) }
                    return
                }
                do {
                    try self.micCapture.start()
                    await MainActor.run {
                        self.captureState = .mic
                        self.refreshStatusIcon()
                    }
                } catch {
                    await MainActor.run { self.handleCaptureError(error) }
                }
            }
        }
    }

    private func handleCaptureError(_ error: Error) {
        captureState = .denied(error.localizedDescription)
        refreshStatusIcon()

        guard let captureError = error as? CaptureError else { return }
        switch captureError {
        case .permissionDenied:
            if !didShowPermissionAlert {
                didShowPermissionAlert = true
                presentPermissionAlert(
                    title: "需要屏幕与系统音频录制权限",
                    message: "允许之后，顶部光条就能跟着系统里播放的音乐跳动。"
                )
            }
        case .micDenied:
            if !didShowPermissionAlert {
                didShowPermissionAlert = true
                presentPermissionAlert(
                    title: "需要麦克风权限",
                    message: "在“系统设置 → 隐私与安全性 → 麦克风”里允许 ParticleBar。"
                )
            }
        default:
            break
        }
    }

    private func presentPermissionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message + "\n\n授权后回到菜单栏，点“重新连接音频”。如果仍然不行，退出并重新打开 ParticleBar。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if title.contains("麦克风") {
                openMicrophoneSettings()
            } else {
                openScreenSettings()
            }
        }
    }

    private func refreshStatusIcon() {
        let symbol: String
        switch captureState {
        case .denied:
            symbol = "waveform.slash"
        default:
            symbol = "waveform"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "粒子音乐条")
        statusItem.button?.image?.isTemplate = true
    }
}
