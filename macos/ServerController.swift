import Foundation
import AppKit
import Combine

enum ServerState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "正在启动…"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }
}

/// 负责拉起/守护内置的 webdav 服务进程
@MainActor
final class ServerController: ObservableObject {

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var pid: Int32 = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastRestartAt: Date?

    let log: LogStore
    let settings: AppSettings

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var healthTimer: Timer?
    private var activityToken: NSObjectProtocol?
    private var wantsRunning = false
    private var healthFailures = 0
    private var restartPending = false
    private var isStopping = false

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    // MARK: 对外控制

    func start() {
        wantsRunning = true
        startProcess()
    }

    func stop() {
        wantsRunning = false
        restartPending = false
        stopProcess()
        endActivity()
        startedAt = nil
        pid = 0
        state = .stopped
    }

    /// 设置变更后热重启
    func restart() {
        guard wantsRunning || state.isActive else { return }
        wantsRunning = true
        log.append("设置已变更，正在重启服务…", source: "服务")
        stopProcess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.wantsRunning else { return }
            self.startProcess()
        }
    }

    func refreshAwakeState() {
        if settings.keepAwake, state.isActive { beginActivity() } else { endActivity() }
    }

    // MARK: 启动

    private func startProcess() {
        guard process == nil else { return }

        if let problem = settings.validationError() {
            state = .failed(problem)
            log.append("无法启动：\(problem)", source: "服务")
            return
        }

        reapStaleServer()

        if !NetInfo.isPortFree(settings.port) {
            let owner = NetInfo.portOwner(settings.port) ?? "未知进程"
            let message = "端口 \(settings.port) 已被占用（\(owner)），请在“共享设置”里换一个端口"
            state = .failed(message)
            log.append(message, source: "服务")
            return
        }

        guard let tool = AppPaths.bundledTool("webdav") else {
            state = .failed("找不到内置 webdav 服务程序，请重新安装应用")
            log.append("内置程序缺失：Contents/Resources/webdav", source: "服务")
            return
        }

        let configURL = settings.writeConfigFile()
        log.append("配置文件：\(configURL.path)", source: "服务")

        let task = Process()
        task.executableURL = tool
        task.arguments = ["-c", configURL.path]
        task.currentDirectoryURL = URL(fileURLWithPath: settings.sharePath)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.log.append(text, source: "服务") }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.log.append(text, source: "服务") }
        }

        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed("服务启动失败：\(error.localizedDescription)")
            log.append("进程启动异常：\(error.localizedDescription)", source: "服务")
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        process = task
        stdoutPipe = outPipe
        stderrPipe = errPipe
        pid = task.processIdentifier
        state = .starting
        healthFailures = 0
        log.append("已启动服务进程（PID \(task.processIdentifier)），监听 0.0.0.0:\(settings.port)", source: "服务")
        beginActivity()
        startHealthTimer()
    }

    // MARK: 停止

    /// 回收上次异常退出（如强制结束应用）时残留的、属于本应用的服务进程
    private func reapStaleServer() {
        guard let listener = NetInfo.listener(port: settings.port) else { return }
        guard let command = NetInfo.processCommand(pid: listener.pid) else { return }
        guard let tool = AppPaths.bundledTool("webdav") else { return }
        if command.contains(tool.path) || command.contains("Contents/Resources/webdav") {
            log.append("发现上次残留的服务进程（PID \(listener.pid)），正在回收", source: "服务")
            kill(listener.pid, SIGTERM)
            for _ in 0..<10 {
                if NetInfo.isPortFree(settings.port) { break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            if !NetInfo.isPortFree(settings.port) {
                kill(listener.pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    private func stopProcess() {
        isStopping = true
        healthTimer?.invalidate()
        healthTimer = nil
        guard let task = process else { isStopping = false; return }
        process = nil

        let terminatingPID = task.processIdentifier
        if task.isRunning {
            task.terminate()
            // 优雅退出 2 秒，仍未退出则强杀
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if task.isRunning {
                    kill(terminatingPID, SIGKILL)
                }
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        pid = 0
        isStopping = false
        log.append("服务已停止", source: "服务")
    }

    private func handleTermination(status: Int32) {
        guard process != nil || state.isActive || wantsRunning else { return }
        process = nil
        pid = 0
        healthTimer?.invalidate()
        healthTimer = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        if isStopping || !wantsRunning {
            state = .stopped
            return
        }

        if status == 0 {
            state = .stopped
            log.append("服务进程已正常退出", source: "服务")
            return
        }

        state = .failed("服务进程意外退出（代码 \(status)）")
        log.append("服务进程意外退出（代码 \(status)），2 秒后自动重启", source: "服务")

        if restartPending { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.wantsRunning else { return }
            self.lastRestartAt = Date()
            self.startProcess()
        }
    }

    // MARK: 健康检查

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.healthTick() }
        }
        RunLoop.main.add(healthTimer!, forMode: .common)
    }

    private func healthTick() {
        guard state.isActive else { return }
        let reachable = NetInfo.canConnect(host: "127.0.0.1", port: settings.port, timeout: 1.0)

        if reachable {
            healthFailures = 0
            if state == .starting {
                state = .running
                startedAt = Date()
                log.append("服务已就绪：http://127.0.0.1:\(settings.port)/", source: "服务")
            }
            return
        }

        healthFailures += 1
        if state == .running, healthFailures == 3 {
            log.append("连续 3 次健康检查失败，尝试重启服务", source: "服务")
            healthFailures = 0
            restart()
        }
        if state == .starting, healthFailures >= 8 {
            state = .failed("服务启动后无响应，请查看日志")
            log.append("启动 16 秒仍无法连接端口 \(settings.port)", source: "服务")
        }
    }

    // MARK: 防休眠

    private func beginActivity() {
        guard activityToken == nil, state.isActive else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled, .userInitiated],
            reason: "WebDAV 服务运行中，保持网络可达"
        )
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
