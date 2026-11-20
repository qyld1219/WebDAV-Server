import Foundation
import Combine

/// Cloudflare 快速隧道 / 命名隧道
@MainActor
final class TunnelController: ObservableObject {

    enum Status: Equatable {
        case off
        case starting
        case online(String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .online: return true
            case .off, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .off: return "未开启"
            case .starting: return "正在建立隧道…"
            case .online: return "已连接"
            case .failed: return "连接失败"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var publicURL: String?
    @Published private(set) var mode: TunnelMode = .lan

    let log: LogStore
    let settings: AppSettings

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var timeoutTimer: Timer?
    private var registrationTimer: Timer?
    private var wantsRunning = false
    private var targetPort: Int = 0
    private var expectedHostname: String = ""
    private var useHTTP2 = false

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    func start(mode: TunnelMode) {
        stop()
        beginProcess(mode: mode)
    }

    /// QUIC（UDP 7844）被拦截时用 HTTP/2 重连，只重试一次
    private func retryWithHTTP2() {
        guard wantsRunning, !useHTTP2 else { return }
        useHTTP2 = true
        log.append("QUIC 连接被网络拦截，改用 HTTP/2 重新建立隧道…", source: "隧道")
        cancelTimers()
        teardownProcess()
        publicURL = nil
        status = .starting
        beginProcess(mode: mode)
    }

    private func beginProcess(mode: TunnelMode) {
        reapStaleTunnel()
        guard mode != .lan else { return }
        guard let tool = AppPaths.bundledTool("cloudflared") else {
            status = .failed("找不到内置 cloudflared，请重新安装应用")
            log.append("内置程序缺失：Contents/Resources/cloudflared", source: "隧道")
            return
        }

        wantsRunning = true
        self.mode = mode
        targetPort = settings.port
        expectedHostname = settings.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        publicURL = nil
        status = .starting

        var arguments: [String] = ["tunnel", "--no-autoupdate", "--loglevel", "info"]
        if useHTTP2 { arguments.append(contentsOf: ["--protocol", "http2"]) }
        switch mode {
        case .quick:
            arguments.append(contentsOf: ["--url", "http://127.0.0.1:\(targetPort)"])
            log.append("正在创建 Cloudflare 快速隧道（免账号，域名随机且重启后会变化）…", source: "隧道")
        case .named:
            let token = settings.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                status = .failed("请先填入命名隧道 Token")
                wantsRunning = false
                return
            }
            arguments.append(contentsOf: ["run", "--token", token])
            log.append("正在运行命名隧道：\(expectedHostname.isEmpty ? "(未填写域名)" : expectedHostname)", source: "隧道")
        case .lan:
            return
        }

        let task = Process()
        task.executableURL = tool
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                guard self.wantsRunning else { return }
                self.wantsRunning = false
                // 已有更具体的原因（如 429 限流）时不再覆盖
                if case .failed = self.status { return }
                self.status = .failed("隧道进程退出（代码 \(proc.terminationStatus)）")
                self.log.append("隧道进程意外退出（代码 \(proc.terminationStatus)）", source: "隧道")
            }
        }

        do {
            try task.run()
        } catch {
            status = .failed("无法启动 cloudflared：\(error.localizedDescription)")
            log.append("cloudflared 启动失败：\(error.localizedDescription)", source: "隧道")
            wantsRunning = false
            return
        }

        process = task
        self.outPipe = outPipe
        self.errPipe = errPipe

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .starting = self.status, self.publicURL == nil else { return }
                if self.mode == .named {
                    self.status = .online(self.displayHost())
                    self.publicURL = self.displayHost()
                    self.log.append("隧道进程仍在运行但未收到注册确认，请在 Cloudflare 后台核对域名状态", source: "隧道")
                } else {
                    self.status = .failed("25 秒内没有拿到公网地址，可能无法访问 Cloudflare（检查网络或代理后重试）")
                    self.log.append("快速隧道建立超时", source: "隧道")
                }
            }
        }
        RunLoop.main.add(timeoutTimer!, forMode: .common)
    }

    /// 拿到地址后，等待与 Cloudflare 边缘真正建立连接
    private func startRegistrationTimer() {
        registrationTimer?.invalidate()
        registrationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .starting = self.status, let url = self.publicURL else { return }
                self.status = .failed("地址 \(url) 已创建，但与 Cloudflare 边缘未能建立连接；通常是本机代理/防火墙拦截了隧道连接")
                self.log.append("隧道已拿到地址但连接边缘超时，应用会保持地址不变，可稍后重试", source: "隧道")
            }
        }
        if let timer = registrationTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func cancelTimers() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        registrationTimer?.invalidate()
        registrationTimer = nil
    }

    private func teardownProcess() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        errPipe = nil
        if let task = process {
            let pid = task.processIdentifier
            task.terminate()
            // 不依赖 isRunning 判断：SIGTERM 被忽略时兜底强杀
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                kill(pid, SIGKILL)
            }
        }
        process = nil
    }

    /// 强杀应用后可能残留 cloudflared 进程（隧道仍在公网暴露），启动/停止时都先回收
    private func reapStaleTunnel(announce: Bool = true) {
        let bundlePath = Bundle.main.bundlePath
        guard !bundlePath.isEmpty else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        do {
            try ps.run()
        } catch { return }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()

        var reaped = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("Contents/Resources/cloudflared"), trimmed.contains(bundlePath) else { continue }
            guard let pidPart = trimmed.split(separator: " ").first, let pid = Int32(pidPart) else { continue }
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                kill(pid, SIGKILL)
            }
            reaped += 1
        }
        if reaped > 0, announce {
            log.append("发现 \(reaped) 个上次残留的隧道进程，正在回收", source: "隧道")
        }
    }

    func stop() {
        wantsRunning = false
        cancelTimers()
        teardownProcess()
        // 兜底：无论进程对象是否还持有引用，都确保不残留 cloudflared 把服务继续暴露在公网
        reapStaleTunnel(announce: false)
        if status.isActive || publicURL != nil {
            log.append("隧道已关闭", source: "隧道")
        }
        status = .off
        publicURL = nil
        useHTTP2 = false
    }

    private func consume(_ text: String) {
        guard !text.isEmpty else { return }
        log.append(text, source: "隧道")
        let lower = text.lowercased()

        if lower.contains("429") || lower.contains("too many requests") {
            wantsRunning = false
            cancelTimers()
            status = .failed("Cloudflare 临时限流（HTTP 429），请等待约 30 秒后重新开启")
            log.append("Cloudflare 对快速隧道申请限流，稍后再试；长期使用建议配置自有域名的命名隧道", source: "隧道")
            return
        }

        if mode == .quick {
            if let match = text.range(of: #"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com"#, options: .regularExpression) {
                let url = String(text[match])
                if publicURL != url {
                    publicURL = url
                    log.append("公网地址已分配：\(url)，正在与 Cloudflare 边缘建立连接…", source: "隧道")
                    timeoutTimer?.invalidate()
                    timeoutTimer = nil
                    startRegistrationTimer()
                }
            }
            if lower.contains("registered tunnel connection") || lower.contains("connection registered") {
                if let url = publicURL {
                    status = .online(url)
                    cancelTimers()
                    log.append("隧道已连通：\(url)", source: "隧道")
                }
            }
            if lower.contains("failed to dial a quic connection") {
                retryWithHTTP2()
                return
            }
        } else if mode == .named {
            if lower.contains("registered tunnel connection") || lower.contains("connection registered") {
                let host = displayHost()
                publicURL = host
                if case .starting = status {
                    status = .online(host)
                }
                log.append("命名隧道已注册成功", source: "隧道")
            } else if lower.contains("unauthorized") || lower.contains("invalid tunnel secret") || lower.contains("failed to unmarshal") {
                status = .failed("Token 无效或已过期，请在 Cloudflare 后台重新复制隧道 Token")
                wantsRunning = false
            }
        }
    }

    private func displayHost() -> String {
        let host = expectedHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return "请填写自有域名" }
        return host.hasPrefix("http") ? host : "https://\(host)"
    }
}
