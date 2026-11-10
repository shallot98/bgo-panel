import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "未登录或 API Token 无效"
        case .server(let message): return message
        case .transport(let message): return "网络请求失败：\(message)"
        case .decoding(let message): return "数据解析错误：\(message)"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    private let store = ServerStore.shared
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "BgoPanelApp/1.0 (iOS)"]
        session = URLSession(configuration: config, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
    }

    private func makeURL(path: String, query: [String: String]? = nil) throws -> URL {
        guard var components = URLComponents(string: store.baseURL) else {
            throw APIError.transport("无效的服务器地址: \(store.baseURL)")
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if let query = query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.transport("无法拼接请求 URL")
        }
        return url
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        query: [String: String]? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method

        // 优先使用永久 API Token（Bearer），次选 Session Cookie
        if let token = store.apiToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = store.sessionCookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        if let body = body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func performData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.transport("非 HTTP 响应")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw APIError.unauthorized
        }

        if httpResponse.statusCode >= 400 {
            if let errObj = try? JSONDecoder().decode(APIResponse.self, from: data), let msg = errObj.error ?? errObj.message {
                throw APIError.server(msg)
            }
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw APIError.server(text)
        }
        return data
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performData(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - API 接口实现

    /// 测试连接连通性与鉴权
    func testConnection() async throws -> Bool {
        let req = try makeRequest(path: "/api/me")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 401 || http.statusCode == 403 { return false }
        if http.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let authed = json["authed"] as? Bool {
                return authed
            }
            return true
        }
        return false
    }

    /// 密码登录并保存 Cookie
    func login(password: String) async throws -> Bool {
        let payload = try JSONSerialization.data(withJSONObject: ["password": password])
        let req = try makeRequest(path: "/api/login", method: "POST", body: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return false }

        if http.statusCode == 200 {
            if let fields = http.allHeaderFields as? [String: String],
               let url = req.url {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                for c in cookies where c.name == "bgo_panel_session" {
                    store.sessionCookie = "\(c.name)=\(c.value)"
                    AppLog.info("登录成功并保存 session cookie")
                    return true
                }
            }
            return true
        }

        if let errObj = try? JSONDecoder().decode(APIResponse.self, from: data), let msg = errObj.error {
            throw APIError.server(msg)
        }
        throw APIError.server("密码错误或登录失败 (\(http.statusCode))")
    }

    /// 获取运行总览
    func fetchOverview() async throws -> OverviewCounts {
        let req = try makeRequest(path: "/api/overview")
        let res: OverviewResponse = try await perform(req)
        return res.counts
    }

    /// 获取房间列表（可按 host 过滤）
    func fetchRooms(host: String? = nil) async throws -> [Room] {
        var query: [String: String] = [:]
        if let host = host, !host.isEmpty, host != "all" {
            query["host"] = host
        } else {
            query["host"] = "all"
        }
        let req = try makeRequest(path: "/api/rooms", query: query)
        let data = try await performData(req)

        if let list = try? JSONDecoder().decode([Room].self, from: data) {
            return list
        }
        if let wrapper = try? JSONDecoder().decode(RoomsResponse.self, from: data) {
            return wrapper.rooms
        }
        do {
            return try JSONDecoder().decode([Room].self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// 获取多节点状态
    func fetchHosts() async throws -> [HostItem] {
        let req = try makeRequest(path: "/api/hosts")
        let hosts: [HostItem] = try await perform(req)
        return hosts
    }

    /// 获取 dyzb AI 衣着评分缓存
    func fetchScores() async throws -> [String: StreamerScore] {
        let req = try makeRequest(path: "/api/scores")
        let res: ScoresResponse = try await perform(req)
        return res.items ?? [:]
    }

    /// 添加房间（支持链接、房间号、分享口令文案）
    func addRoom(urlOrText: String, mode: String = "permanent", host: String = "boh") async throws -> String {
        let dict: [String: Any] = [
            "url": urlOrText,
            "mode": mode,
            "host": host
        ]
        let payload = try JSONSerialization.data(withJSONObject: dict)
        let req = try makeRequest(path: "/api/rooms", method: "POST", body: payload)
        let res: APIResponse = try await perform(req)
        if let err = res.error { throw APIError.server(err) }
        return res.message ?? "添加成功"
    }

    /// 开始监听/录制
    func startRoom(id: String, host: String) async throws {
        let req = try makeRequest(path: "/api/rooms/\(id)/start", method: "POST", query: ["host": host])
        let _: APIResponse = try await perform(req)
    }

    /// 停止监听/录制
    func stopRoom(id: String, host: String) async throws {
        let req = try makeRequest(path: "/api/rooms/\(id)/stop", method: "POST", query: ["host": host])
        let _: APIResponse = try await perform(req)
    }

    /// 修改房间模式（临时时间 / 录 N 场 / 永久）
    func updateRoomMode(id: String, host: String, body: [String: Any]) async throws {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let req = try makeRequest(path: "/api/rooms/\(id)/mode", method: "POST", query: ["host": host], body: payload)
        let _: APIResponse = try await perform(req)
    }

    /// 删除房间
    func deleteRoom(id: String, host: String) async throws {
        let req = try makeRequest(path: "/api/rooms/\(id)", method: "DELETE", query: ["host": host])
        let _: APIResponse = try await perform(req)
    }

    /// 实时查询房间直播场次信息（用于跳转抖音直播间）
    func fetchRoomLiveInfo(id: String, host: String) async throws -> RoomLiveInfo {
        let req = try makeRequest(path: "/api/rooms/\(id)/live-info", query: ["host": host])
        return try await perform(req)
    }
}
