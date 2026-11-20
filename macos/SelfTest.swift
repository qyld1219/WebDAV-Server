import Foundation
import AppKit

/// 无界面自检：验证配置生成、内置服务进程、鉴权与读写协议、二维码、网络工具
@MainActor
enum SelfTest {

    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
            if !ok { failures += 1 }
        }

        print("==== WebDAV 服务器 自检 ====")
        print("系统版本：\(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 1. 二维码
        check("二维码生成", QRCodeGenerator.image(text: "http://192.168.1.2:8080") != nil)

        // 2. 局域网地址
        if let ip = NetInfo.lanIPv4() {
            check("局域网 IPv4 探测", NetInfo.isValidIPv4(ip), ip)
        } else {
            print("INFO 未检测到局域网 IPv4（可能未联网），跳过")
        }

        // 3. 配置 YAML（含特殊字符转义）
        let shareDir = "/tmp/webdav-selftest-share dir"
        let username = "测试用户"
        let password = "p@ss\"w\\ord"
        let yaml = WebDAVConfigSpec.sample(port: 18980, share: shareDir, username: username, password: password).yaml
        check("配置含目录项", yaml.contains("directory: \"\(shareDir)\""), "双引号路径")
        check("配置含用户项", yaml.contains("users:") && yaml.contains("username:"))
        check("配置转义反斜杠", yaml.contains("w\\\\ord"))
        check("配置含权限", yaml.contains("permissions: CRUD"))

        // 4. 选一个空闲端口
        var port = 0
        for candidate in 18980...18999 where NetInfo.isPortFree(candidate) {
            port = candidate
            break
        }
        guard port != 0 else {
            check("查找空闲端口", false)
            print("自检失败")
            return 1
        }
        check("查找空闲端口", true, "\(port)")
        check("端口被识别为可用", NetInfo.isPortFree(port))

        // 5. 准备共享目录与配置
        let fm = FileManager.default
        try? fm.removeItem(atPath: shareDir)
        try? fm.createDirectory(atPath: shareDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: shareDir + "/sub", withIntermediateDirectories: true)
        try? "hello-dav\n".write(toFile: shareDir + "/hello.txt", atomically: true, encoding: .utf8)

        let configPath = "/tmp/webdav-selftest-\(port).yml"
        let spec = WebDAVConfigSpec(
            port: port,
            sharePath: shareDir,
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
        do {
            try spec.yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
            check("写入配置文件", true, configPath)
        } catch {
            check("写入配置文件", false, error.localizedDescription)
            return 1
        }

        // 6. 启动内置服务
        guard let tool = AppPaths.bundledTool("webdav") else {
            check("定位内置 webdav 可执行文件", false)
            return 1
        }
        check("定位内置 webdav 可执行文件", true, tool.path)

        let logPath = "/tmp/webdav-selftest-\(port).log"
        fm.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let task = Process()
        task.executableURL = tool
        task.arguments = ["-c", configPath]
        task.standardOutput = logHandle
        task.standardError = logHandle
        do {
            try task.run()
        } catch {
            check("启动服务进程", false, error.localizedDescription)
            return 1
        }

        var ready = false
        for _ in 0..<40 {
            if NetInfo.canConnect(host: "127.0.0.1", port: port, timeout: 0.5) { ready = true; break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        check("服务端口可连接", ready)
        if !ready {
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            print("服务日志：\n\(log)")
            task.terminate()
            return 1
        }

        // 7. 协议与鉴权
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let credentials = "\(username):\(password)"

        let unauth = request(base, method: "PROPFIND", auth: nil, depth: "1")
        check("无凭证被拒绝", unauth.status == 401, "HTTP \(unauth.status)")

        let wrong = request(base, method: "PROPFIND", auth: "\(username):wrong-pass", depth: "1")
        check("错误密码被拒绝", wrong.status == 401, "HTTP \(wrong.status)")

        let propfind = request(base, method: "PROPFIND", auth: credentials, depth: "1")
        check("PROPFIND 返回 207", propfind.status == 207, "HTTP \(propfind.status)")
        check("目录列表包含 hello.txt", String(data: propfind.body, encoding: .utf8)?.contains("hello.txt") == true)

        let putBody = Data("upload-ok".utf8)
        let putURL = base.appendingPathComponent("uploaded.txt")
        let put = request(putURL, method: "PUT", auth: credentials, body: putBody)
        check("PUT 新建文件返回 201", put.status == 201, "HTTP \(put.status)")

        let get = request(putURL, method: "GET", auth: credentials)
        check("GET 回读内容一致", get.status == 200 && String(data: get.body, encoding: .utf8) == "upload-ok",
              "HTTP \(get.status)")

        let delete = request(putURL, method: "DELETE", auth: credentials)
        check("DELETE 删除文件返回 204", delete.status == 204, "HTTP \(delete.status)")

        let mkcol = request(base.appendingPathComponent("newdir"), method: "MKCOL", auth: credentials)
        check("MKCOL 创建目录返回 201", mkcol.status == 201, "HTTP \(mkcol.status)")

        // 8. 停止
        task.terminate()
        task.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        check("停止后端口释放", NetInfo.isPortFree(port))
        try? logHandle?.close()
        try? fm.removeItem(atPath: configPath)
        try? fm.removeItem(atPath: logPath)
        try? fm.removeItem(atPath: shareDir)

        print("==== 结果：\(failures == 0 ? "全部通过" : "\(failures) 项失败") ====")
        return failures == 0 ? 0 : 1
    }

    private static func request(_ url: URL, method: String, auth: String?, body: Data? = nil, depth: String? = nil) -> (status: Int, body: Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 10
        if let depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
        if let auth, let data = auth.data(using: .utf8) {
            req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = body }

        var status = -1
        var payload = Data()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            payload = data ?? Data()
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return (status, payload)
    }
}
