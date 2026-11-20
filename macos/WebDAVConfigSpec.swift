import Foundation

/// 内置 WebDAV 服务的配置文件内容（可单独构造，便于测试）
struct WebDAVConfigSpec {
    var port: Int
    var sharePath: String
    var permissions: String
    var showListing: Bool
    var username: String
    var password: String
    var allowAnonymous: Bool
    var useTLS: Bool
    var certPath: String
    var keyPath: String
    var behindProxy: Bool

    var yaml: String {
        var lines: [String] = []
        lines.append("# 由 WebDAV 服务器 App 自动生成，手动修改会在下次启动时被覆盖")
        lines.append("address: 0.0.0.0")
        lines.append("port: \(port)")
        if useTLS {
            lines.append("tls: true")
            lines.append("cert: \(YAML.quote(certPath))")
            lines.append("key: \(YAML.quote(keyPath))")
            lines.append("hsts: false")
        }
        lines.append("directory: \(YAML.quote(sharePath))")
        lines.append("permissions: \(permissions)")
        lines.append("prefix: /")
        lines.append("debug: false")
        lines.append("noSniff: false")
        lines.append("behindProxy: \(behindProxy ? "true" : "false")")
        lines.append("listing:")
        lines.append("  enabled: \(showListing ? "true" : "false")")
        lines.append("  show_path: true")
        lines.append("log:")
        lines.append("  format: console")
        lines.append("  colors: false")
        lines.append("  outputs:")
        lines.append("    - stderr")
        lines.append("cors:")
        lines.append("  enabled: true")
        lines.append("  credentials: true")
        lines.append("  allowed_hosts:")
        lines.append("    - \"*\"")
        if !allowAnonymous, !username.isEmpty {
            lines.append("users:")
            lines.append("  - username: \(YAML.quote(username))")
            lines.append("    password: \(YAML.quote(password))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sample(port: Int, share: String, username: String, password: String) -> WebDAVConfigSpec {
        WebDAVConfigSpec(
            port: port,
            sharePath: share,
            permissions: "CRUD",
            showListing: true,
            username: username,
            password: password,
            allowAnonymous: false,
            useTLS: false,
            certPath: "",
            keyPath: "",
            behindProxy: false
        )
    }
}
