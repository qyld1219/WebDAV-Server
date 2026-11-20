import Foundation
import Combine

enum TunnelMode: String, CaseIterable, Identifiable {
    case lan = "lan"
    case quick = "quick"
    case named = "named"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lan: return "局域网 / 端口映射"
        case .quick: return "Cloudflare 快速隧道"
        case .named: return "自有域名（命名隧道）"
        }
    }

    var shortTitle: String {
        switch self {
        case .lan: return "局域网"
        case .quick: return "快速隧道"
        case .named: return "自有域名"
        }
    }
}

/// 应用设置：非敏感项存 UserDefaults，密码/令牌存 Keychain。
final class AppSettings: ObservableObject {

    private static let storageKey = "webdav.settings.v1"

    @Published var sharePath: String { didSet { save() } }
    @Published var port: Int { didSet { save() } }
    @Published var username: String { didSet { save() } }
    @Published var password: String { didSet { save() } }
    @Published var allowAnonymous: Bool { didSet { save() } }
    @Published var readOnly: Bool { didSet { save() } }
    @Published var showListing: Bool { didSet { save() } }
    @Published var keepAwake: Bool { didSet { save() } }
    @Published var autoStartServer: Bool { didSet { save() } }
    @Published var launchAtLogin: Bool { didSet { save() } }

    @Published var useTLS: Bool { didSet { save() } }
    @Published var certPath: String { didSet { save() } }
    @Published var keyPath: String { didSet { save() } }

    @Published var tunnelMode: TunnelMode { didSet { save() } }
    @Published var tunnelToken: String { didSet { KeychainStore.set(tunnelToken, key: "tunnelToken"); save() } }
    @Published var publicHostname: String { didSet { save() } }

    @Published var ddnsEnabled: Bool { didSet { save() } }
    @Published var cfToken: String { didSet { KeychainStore.set(cfToken, key: "cfToken"); save() } }
    @Published var cfZone: String { didSet { save() } }
    @Published var cfRecord: String { didSet { save() } }
    @Published var ddnsIntervalMinutes: Int { didSet { save() } }

    init() {
        let stored = AppSettings.loadDict()
        let defaultShare = AppSettings.defaultSharePath()
        AppSettings.ensureDirectory(defaultShare)

        let storedPassword = KeychainStore.get("password")
        let resolvedPassword = storedPassword.isEmpty ? AppSettings.randomPassword() : storedPassword
        if storedPassword.isEmpty { KeychainStore.set(resolvedPassword, key: "password") }

        sharePath = stored["sharePath"] as? String ?? defaultShare
        port = stored["port"] as? Int ?? 8080
        username = stored["username"] as? String ?? "webdav"
        password = resolvedPassword
        allowAnonymous = stored["allowAnonymous"] as? Bool ?? false
        readOnly = stored["readOnly"] as? Bool ?? false
        showListing = stored["showListing"] as? Bool ?? true
        keepAwake = stored["keepAwake"] as? Bool ?? true
        autoStartServer = stored["autoStartServer"] as? Bool ?? false
        launchAtLogin = stored["launchAtLogin"] as? Bool ?? false
        useTLS = stored["useTLS"] as? Bool ?? false
        certPath = stored["certPath"] as? String ?? ""
        keyPath = stored["keyPath"] as? String ?? ""
        tunnelMode = TunnelMode(rawValue: stored["tunnelMode"] as? String ?? "") ?? .lan
        tunnelToken = KeychainStore.get("tunnelToken")
        publicHostname = stored["publicHostname"] as? String ?? ""
        ddnsEnabled = stored["ddnsEnabled"] as? Bool ?? false
        cfToken = KeychainStore.get("cfToken")
        cfZone = stored["cfZone"] as? String ?? ""
        cfRecord = stored["cfRecord"] as? String ?? ""
        ddnsIntervalMinutes = stored["ddnsIntervalMinutes"] as? Int ?? 10
    }

    // MARK: 校验

    /// 返回第一个阻断性问题，无问题返回 nil。
    func validationError() -> String? {
        if sharePath.isEmpty { return "请先选择要共享的文件夹" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sharePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "共享文件夹不存在：\(sharePath)"
        }
        if port < 1024 || port > 65535 { return "端口需在 1024–65535 之间" }
        if allowAnonymous == false, username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "请填写用户名，或开启“允许匿名访问”"
        }
        if allowAnonymous == false, password.isEmpty { return "请填写密码" }
        if useTLS {
            if certPath.isEmpty || keyPath.isEmpty { return "启用 HTTPS 需要选择证书和私钥文件" }
            if !FileManager.default.fileExists(atPath: certPath) { return "证书文件不存在" }
            if !FileManager.default.fileExists(atPath: keyPath) { return "私钥文件不存在" }
        }
        return nil
    }

    var effectivePermissions: String { readOnly ? "R" : "CRUD" }

    var configSpec: WebDAVConfigSpec {
        WebDAVConfigSpec(
            port: port,
            sharePath: sharePath,
            permissions: effectivePermissions,
            showListing: showListing,
            username: username,
            password: password,
            allowAnonymous: allowAnonymous,
            useTLS: useTLS,
            certPath: certPath,
            keyPath: keyPath,
            behindProxy: tunnelMode != .lan
        )
    }

    // MARK: 配置文件

    func makeConfigYAML() -> String {
        configSpec.yaml
    }

    func writeConfigFile() -> URL {
        let url = AppPaths.configURL
        let content = makeConfigYAML()
        try? content.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // MARK: 持久化

    private func save() {
        var dict: [String: Any] = [:]
        dict["sharePath"] = sharePath
        dict["port"] = port
        dict["username"] = username
        dict["allowAnonymous"] = allowAnonymous
        dict["readOnly"] = readOnly
        dict["showListing"] = showListing
        dict["keepAwake"] = keepAwake
        dict["autoStartServer"] = autoStartServer
        dict["launchAtLogin"] = launchAtLogin
        dict["useTLS"] = useTLS
        dict["certPath"] = certPath
        dict["keyPath"] = keyPath
        dict["tunnelMode"] = tunnelMode.rawValue
        dict["publicHostname"] = publicHostname
        dict["ddnsEnabled"] = ddnsEnabled
        dict["cfZone"] = cfZone
        dict["cfRecord"] = cfRecord
        dict["ddnsIntervalMinutes"] = ddnsIntervalMinutes
        UserDefaults.standard.set(dict, forKey: AppSettings.storageKey)
    }

    private static func loadDict() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
    }

    static func defaultSharePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Desktop/WebDAV共享", isDirectory: true).path
    }

    static func ensureDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }
}
