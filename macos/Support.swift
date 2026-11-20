import Foundation
import AppKit
import Security
import CoreImage
import Darwin

// MARK: - Keychain（敏感信息只存钥匙串）

enum KeychainStore {
    private static let service = "com.malixi.webdavserver"

    static func set(_ value: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

// MARK: - 网络信息

enum NetInfo {

    /// 局域网 IPv4 地址，优先 en0/en1，排除回环、链路本地、虚拟网卡。
    static func lanIPv4() -> String? {
        var candidates: [(name: String, ip: String)] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            defer { cursor = pointer.pointee.ifa_next }
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"),
                  !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("bridge"), !name.hasPrefix("anpi") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sock = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr.self)
            let len = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(sock, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254"), ip != "127.0.0.1", ip != "0.0.0.0" else { continue }
            candidates.append((name, ip))
        }
        // 优先物理网卡
        for prefix in ["en0", "en1", "en2"] {
            if let hit = candidates.first(where: { $0.name == prefix }) { return hit.ip }
        }
        return candidates.first?.ip
    }

    static func machineName() -> String {
        if let local = Host.current().localizedName, !local.isEmpty { return local }
        return ProcessInfo.processInfo.hostName
    }

    /// 异步获取公网 IPv4，多源回退。
    static func publicIPv4() async -> String? {
        let sources = [
            "https://api.ipify.org",
            "https://ipv4.icanhazip.com",
            "https://ifconfig.me/ip",
            "https://1.1.1.1/cdn-cgi/trace"
        ]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("curl/8", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { continue }
                let ip: String
                if source.contains("cdn-cgi/trace") {
                    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else { continue }
                    ip = String(line.dropFirst(3))
                } else {
                    ip = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if isValidIPv4(ip) { return ip }
            } catch {
                continue
            }
        }
        return nil
    }

    static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255, !part.isEmpty else { return false }
            return true
        }
    }

    // MARK: 端口 / 连通性

    /// 端口是否可绑定（可绑定 = 空闲）
    static func isPortFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 谁占用了端口（用于提示）
    static func portOwner(_ port: Int) -> String? {
        listener(port: port)?.command
    }

    /// 占用该端口的监听进程
    static func listener(port: Int) -> (pid: Int32, command: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var pid: Int32 = 0
        var command = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("c") {
                command = String(line.dropFirst())
            }
            if pid != 0, !command.isEmpty { return (pid, command) }
        }
        return nil
    }

    /// 进程完整命令行
    static func processCommand(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 带超时的 TCP 探测
    static func canConnect(host: String, port: Int, timeout: TimeInterval = 1.0) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        let started = Date()
        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var polled = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let remaining = Int32(max(1, timeout * 1000))
        let ready = poll(&polled, 1, remaining)
        _ = Date().timeIntervalSince(started)
        guard ready > 0 else { return false }
        var errorCode: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorCode, &length)
        return errorCode == 0
    }
}

// MARK: - 二维码

enum QRCodeGenerator {
    static func image(text: String, scale: CGFloat = 10) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - YAML 工具

enum YAML {
    static func quote(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - 路径

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WebDAVServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var configURL: URL { supportDirectory.appendingPathComponent("config.yml") }

    /// 打包在 .app/Contents/Resources 内的辅助程序
    static func bundledTool(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) { return url }
        let fallback = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)")
        if FileManager.default.isExecutableFile(atPath: fallback.path) { return fallback }
        if let dev = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }
}
