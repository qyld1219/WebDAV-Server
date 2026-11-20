import Foundation
import Combine

/// Cloudflare DDNS：公网 IP 变化时自动更新自有域名的 A 记录
@MainActor
final class DDNSController: ObservableObject {

    enum Phase {
        case off, idle, working, ok, error
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var message: String = "未启用"
    @Published private(set) var publicIP: String?
    @Published private(set) var lastSyncAt: Date?

    let log: LogStore
    let settings: AppSettings

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private static let lastIPKey = "webdav.ddns.lastIP"

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    var isRunning: Bool { timer != nil }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, settings.ddnsIntervalMinutes)) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkOnce(force: false) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        phase = .idle
        message = "已启用，等待首次同步"
        log.append("DDNS 已启用，每 \(settings.ddnsIntervalMinutes) 分钟检查一次", source: "DDNS")
        Task { @MainActor in await self.checkOnce(force: true) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        phase = .off
        message = "未启用"
    }

    func refreshNow(force: Bool = true) {
        Task { @MainActor in await self.checkOnce(force: force) }
    }

    /// 系统唤醒后调用：只在 IP 变化时更新
    func refreshIfNeededOnWake() async {
        await checkOnce(force: false)
    }

    func updatePublicIP(_ ip: String) {
        publicIP = ip
    }

    /// 校验 Token 是否可用（UI 上的“验证凭据”按钮）
    func verifyCredentials() async -> String {
        let api = CloudflareAPI(token: settings.cfToken)
        do {
            let status = try await api.verifyToken()
            _ = try await api.zoneID(name: settings.cfZone.trimmingCharacters(in: .whitespacesAndNewlines))
            return "凭据有效（状态：\(status)），域名 \(settings.cfZone) 可访问"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: 主流程

    private func checkOnce(force: Bool) async {
        let token = settings.cfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = settings.cfZone.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = settings.cfRecord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !token.isEmpty, !zone.isEmpty, !record.isEmpty else {
            phase = .error
            message = "请填写 API Token、域名和记录名"
            return
        }

        phase = .working
        message = "正在获取公网 IP…"

        guard let ip = await NetInfo.publicIPv4() else {
            phase = .error
            message = "无法获取公网 IP（网络可能受限）"
            log.append("获取公网 IP 失败", source: "DDNS")
            return
        }
        publicIP = ip

        let lastIP = UserDefaults.standard.string(forKey: Self.lastIPKey)
        if !force, lastIP == ip, lastSyncAt != nil {
            phase = .idle
            message = "公网 IP 未变化（\(ip)）"
            return
        }

        message = "正在更新 Cloudflare 记录…"
        let api = CloudflareAPI(token: token)
        do {
            let zoneID = try await api.zoneID(name: zone)
            if let existing = try await api.existingARecord(zoneID: zoneID, fqdn: record) {
                if existing.content == ip {
                    lastSyncAt = Date()
                    phase = .ok
                    message = "记录已是最新：\(record) → \(ip)"
                    UserDefaults.standard.set(ip, forKey: Self.lastIPKey)
                    return
                }
                try await api.updateARecord(zoneID: zoneID, recordID: existing.id, ip: ip)
                if existing.proxied {
                    log.append("提示：该记录开启了 Cloudflare 代理（橙云），WebDAV 的 PROPFIND 等方法可能被拦截；建议关闭代理（灰云）", source: "DDNS")
                }
                log.append("已更新 \(record)：\(existing.content) → \(ip)", source: "DDNS")
            } else {
                try await api.createARecord(zoneID: zoneID, fqdn: record, ip: ip)
                log.append("已新建 A 记录 \(record) → \(ip)", source: "DDNS")
            }
            UserDefaults.standard.set(ip, forKey: Self.lastIPKey)
            lastSyncAt = Date()
            phase = .ok
            message = "已更新：\(record) → \(ip)"
        } catch {
            phase = .error
            message = error.localizedDescription
            log.append("DDNS 更新失败：\(error.localizedDescription)", source: "DDNS")
        }
    }
}
