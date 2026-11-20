import Foundation

enum CloudflareError: LocalizedError {
    case auth(String)
    case api(String)
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .auth(let message): return "Cloudflare 凭据无效：\(message)"
        case .api(let message): return "Cloudflare 接口返回错误：\(message)"
        case .network(let message): return "网络请求失败：\(message)"
        case .parse(let message): return "响应解析失败：\(message)"
        }
    }
}

struct CloudflareAPI {
    let token: String

    private var trimedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4" + path) else {
            throw CloudflareError.parse("非法路径 \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(trimedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudflareError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudflareError.network("无 HTTP 响应")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 401 || http.statusCode == 403 {
            throw CloudflareError.auth("HTTP \(http.statusCode)")
        }

        guard (json["success"] as? Bool) == true else {
            let errors = json["errors"] as? [[String: Any]] ?? []
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: "；")
            throw CloudflareError.api(message.isEmpty ? "HTTP \(http.statusCode)" : message)
        }
        return json["result"] ?? [:]
    }

    /// 校验 API Token
    func verifyToken() async throws -> String {
        let result = try await request("GET", "/user/tokens/verify")
        guard let dict = result as? [String: Any], let status = dict["status"] as? String else {
            throw CloudflareError.parse("缺少 status 字段")
        }
        return status
    }

    func zoneID(name: String) async throws -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let result = try await request("GET", "/zones?name=\(encoded)&per_page=50")
        guard let zones = result as? [[String: Any]] else {
            throw CloudflareError.parse("zone 列表格式异常")
        }
        guard let zone = zones.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }),
              let id = zone["id"] as? String else {
            throw CloudflareError.api("账号下找不到域名 \(name)，请确认已添加到 Cloudflare")
        }
        return id
    }

    /// 返回现有 A 记录的 (记录 ID, 当前内容, 是否走 Cloudflare 代理)
    func existingARecord(zoneID: String, fqdn: String) async throws -> (id: String, content: String, proxied: Bool)? {
        let encoded = fqdn.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fqdn
        let result = try await request("GET", "/zones/\(zoneID)/dns_records?type=A&name=\(encoded)")
        guard let records = result as? [[String: Any]] else { return nil }
        guard let record = records.first,
              let id = record["id"] as? String,
              let content = record["content"] as? String else { return nil }
        return (id, content, record["proxied"] as? Bool ?? false)
    }

    func updateARecord(zoneID: String, recordID: String, ip: String) async throws {
        _ = try await request("PATCH", "/zones/\(zoneID)/dns_records/\(recordID)", body: ["content": ip])
    }

    func createARecord(zoneID: String, fqdn: String, ip: String, proxied: Bool = false) async throws {
        _ = try await request("POST", "/zones/\(zoneID)/dns_records", body: [
            "type": "A",
            "name": fqdn,
            "content": ip,
            "ttl": 120,
            "proxied": proxied
        ])
    }
}
