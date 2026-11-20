import Foundation
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {

    static var shared: AppModel?

    let settings: AppSettings
    let log: LogStore
    let server: ServerController
    let tunnel: TunnelController
    let ddns: DDNSController

    @Published var selectedTab: Int = 0
    @Published var qrPayload: String = ""
    @Published var showQR: Bool = false
    @Published var toast: String?
    @Published var ddnsVerifyResult: String = ""
    @Published var ddnsVerifying: Bool = false
    @Published var portStatus: String = "端口可用"
    @Published var portStatusWarning: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var restartWorkItem: DispatchWorkItem?
    private var lastServerSignature: String = ""
    private var lastTunnelPort: Int = 0
    private var wakeObserver: NSObjectProtocol?

    init() {
        let settings = AppSettings()
        let log = LogStore()
        self.settings = settings
        self.log = log
        self.server = ServerController(settings: settings, log: log)
        self.tunnel = TunnelController(settings: settings, log: log)
        self.ddns = DDNSController(settings: settings, log: log)
        self.lastServerSignature = serverSignature()
        self.lastTunnelPort = settings.port

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 先于赋值触发，下一轮循环读取新值
                DispatchQueue.main.async { self?.settingsChanged() }
            }
            .store(in: &cancellables)

        // 子控制器的状态变化转发给根视图（嵌套 ObservableObject 需要手动转发）
        let childPublishers = [server.objectWillChange, tunnel.objectWillChange, ddns.objectWillChange]
        for publisher in childPublishers {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                    self?.refreshPortStatus()
                }
                .store(in: &cancellables)
        }

        refreshPortStatus()
        let portTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPortStatus() }
        }
        RunLoop.main.add(portTimer, forMode: .common)

        settings.$tunnelMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.tunnelModeChanged(mode) }
            .store(in: &cancellables)

        settings.$ddnsEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.ddnsToggled(enabled) }
            .store(in: &cancellables)

        // 唤醒后立刻补一次 DDNS 检查
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.ddnsEnabled else { return }
                self.log.append("系统唤醒，立即检查公网 IP", source: "DDNS")
                await self.ddns.refreshIfNeededOnWake()
            }
        }
    }

    // MARK: 生命周期

    func bootstrap() {
        publishSystemInfo()
        if settings.launchAtLogin { _ = applyLaunchAgent(enabled: true) }
        if settings.autoStartServer {
            log.append("已开启“启动应用时自动开始共享”，正在启动服务", source: "App")
            startAll()
        }
        if settings.ddnsEnabled {
            ddns.start()
        }
    }

    func shutdown() {
        tunnel.stop()
        server.stop()
        ddns.stop()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    // MARK: 服务控制

    func startAll() {
        guard !server.state.isActive else { return }
        server.start()
        if settings.tunnelMode != .lan {
            lastTunnelPort = settings.port
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.settings.tunnelMode != .lan else { return }
                self.tunnel.start(mode: self.settings.tunnelMode)
            }
        }
        selectedTab = 0
    }

    func stopAll() {
        tunnel.stop()
        server.stop()
    }

    func toggleServer() {
        if server.state.isActive {
            stopAll()
        } else {
            startAll()
        }
    }

    func openShareFolder() {
        let url = URL(fileURLWithPath: settings.sharePath)
        NSWorkspace.shared.open(url)
    }

    func chooseShareFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此文件夹"
        panel.message = "选择要通过 WebDAV 共享出去的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            settings.sharePath = url.path
        }
    }

    func chooseFile(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }

    // MARK: 地址

    var lanAddress: String? {
        guard let ip = NetInfo.lanIPv4() else { return nil }
        return "http://\(ip):\(settings.port)"
    }

    var lanAddressWithCredentials: String? {
        guard let address = lanAddress else { return nil }
        if settings.allowAnonymous { return address }
        return "http://\(settings.username):\(settings.password)@\(address.replacingOccurrences(of: "http://", with: ""))"
    }

    var remoteAddress: String? {
        if case .online(let url) = tunnel.status { return url }
        return nil
    }

    var primaryAddress: String {
        remoteAddress ?? lanAddress ?? "http://127.0.0.1:\(settings.port)"
    }

    func copy(_ text: String, feedback: String = "已复制到剪贴板") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast(feedback)
    }

    func presentQR(for text: String) {
        qrPayload = text
        showQR = true
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    var connectionSummary: String {
        var lines: [String] = []
        lines.append("WebDAV 服务器连接信息")
        if let lan = lanAddress { lines.append("局域网地址：\(lan)") }
        if let remote = remoteAddress { lines.append("外网地址：\(remote)") }
        lines.append("用户名：\(settings.allowAnonymous ? "（匿名，无需密码）" : settings.username)")
        if !settings.allowAnonymous { lines.append("密码：\(settings.password)") }
        lines.append("权限：\(settings.readOnly ? "只读" : "可读写")")
        return lines.joined(separator: "\n")
    }

    // MARK: 变更响应

    private func serverSignature() -> String {
        [
            settings.sharePath,
            String(settings.port),
            settings.username,
            settings.password,
            String(settings.allowAnonymous),
            String(settings.readOnly),
            String(settings.showListing),
            String(settings.useTLS),
            settings.certPath,
            settings.keyPath
        ].joined(separator: "|")
    }

    /// 端口占用提示由模型统一计算并发布，界面只读结果，避免视图内反复调用 lsof
    private func refreshPortStatus() {
        let port = settings.port
        var text = "端口可用"
        var warning = false
        if server.state.isActive {
            text = "服务运行中，正在使用该端口"
        } else if !NetInfo.isPortFree(port) {
            if let owner = NetInfo.portOwner(port) {
                text = "端口被 \(owner) 占用"
            } else {
                text = "端口被占用，请更换"
            }
            warning = true
        }
        if text != portStatus { portStatus = text }
        if warning != portStatusWarning { portStatusWarning = warning }
    }

    private func settingsChanged() {
        let signature = serverSignature()
        guard signature != lastServerSignature else { return }
        lastServerSignature = signature

        guard server.state.isActive else { return }
        scheduleServerRestart()
    }

    private func scheduleServerRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log.append("共享配置已变更，自动重启服务生效", source: "App")
            let portChanged = self.lastTunnelPort != self.settings.port
            self.server.restart()
            self.lastTunnelPort = self.settings.port
            if portChanged, self.settings.tunnelMode != .lan, self.tunnel.status.isActive {
                self.tunnel.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.settings.tunnelMode != .lan else { return }
                    self.tunnel.start(mode: self.settings.tunnelMode)
                }
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func tunnelModeChanged(_ mode: TunnelMode) {
        // 切换方式时只关闭已有隧道，不擅自开新隧道；由用户点按钮明确开启
        if mode == .lan {
            if tunnel.status.isActive {
                tunnel.stop()
                showToast("已切换为局域网模式，隧道已关闭")
            }
            return
        }
        if tunnel.status.isActive {
            tunnel.stop()
        }
        showToast("已切换到「\(mode.title)」，点下方按钮开启")
    }

    private func ddnsToggled(_ enabled: Bool) {
        if enabled {
            ddns.start()
        } else {
            ddns.stop()
        }
    }

    func applyTunnel() {
        if tunnel.status.isActive {
            tunnel.stop()
        } else {
            guard server.state.isActive else {
                showToast("请先启动 WebDAV 服务")
                return
            }
            tunnel.start(mode: settings.tunnelMode)
        }
    }

    func verifyDDNS() {
        ddnsVerifying = true
        ddnsVerifyResult = "正在验证…"
        Task {
            let result = await ddns.verifyCredentials()
            self.ddnsVerifying = false
            self.ddnsVerifyResult = result
        }
    }

    func refreshPublicIP() {
        Task {
            if let ip = await NetInfo.publicIPv4() {
                self.ddns.updatePublicIP(ip)
                self.showToast("公网 IP：\(ip)")
            } else {
                self.showToast("无法获取公网 IP，检查网络连接")
            }
        }
    }

    // MARK: 开机自启

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        let result = applyLaunchAgent(enabled: enabled)
        if result != nil {
            settings.launchAtLogin = false
        }
        return result
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.malixi.webdavserver.plist")
    }

    private func applyLaunchAgent(enabled: Bool) -> String? {
        let fm = FileManager.default
        let path = launchAgentURL.path
        if enabled {
            try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.malixi.webdavserver</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            do {
                try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            } catch {
                return "写入开机启动项失败：\(error.localizedDescription)"
            }
            _ = runLaunchctl(["load", "-w", path])
            return nil
        } else {
            _ = runLaunchctl(["unload", "-w", path])
            try? fm.removeItem(atPath: path)
            return nil
        }
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    private func publishSystemInfo() {
        log.append("系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", source: "App")
        if let ip = NetInfo.lanIPv4() {
            log.append("局域网 IP：\(ip)，监听端口 \(settings.port)", source: "App")
        } else {
            log.append("未检测到局域网 IPv4 地址（可能未连接网络）", source: "App")
        }
    }
}
