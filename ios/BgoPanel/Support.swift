import Foundation
import UIKit

enum AppLog {
    static func info(_ message: String) { NSLog("[BgoPanel] %@", message) }
    static func error(_ message: String) { NSLog("[BgoPanel ERROR] %@", message) }
}

/// 主题与设计规范（深色终端控制台风格）
enum Theme {
    static let background = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
    static let cardBackground = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    static let cardSelected = UIColor(red: 0.14, green: 0.14, blue: 0.17, alpha: 1.0)
    static let border = UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1.0)

    static let recordingRed = UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)   // #FF3B30
    static let listeningGreen = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0) // #34C759
    static let warningYellow = UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1.0)  // #FF9F0A
    static let permanentBlue = UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1.0)  // #007AFF
    static let scoreGold = UIColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1.0)      // #FFD60A

    static let textPrimary = UIColor(white: 0.95, alpha: 1.0)
    static let textSecondary = UIColor(white: 0.60, alpha: 1.0)
    static let textMuted = UIColor(white: 0.38, alpha: 1.0)

    /// 获取主播名称首字（大写/汉字）作为头像文字
    static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "播" }
        return String(first).uppercased()
    }

    /// 根据主播名称哈希生成稳定的专属渐变底色
    static func avatarColor(for name: String) -> UIColor {
        let palette: [UIColor] = [
            UIColor(red: 0.20, green: 0.50, blue: 0.90, alpha: 1.0), // 蓝
            UIColor(red: 0.15, green: 0.68, blue: 0.38, alpha: 1.0), // 绿
            UIColor(red: 0.58, green: 0.32, blue: 0.88, alpha: 1.0), // 紫
            UIColor(red: 0.92, green: 0.40, blue: 0.20, alpha: 1.0), // 橙
            UIColor(red: 0.85, green: 0.25, blue: 0.45, alpha: 1.0), // 玫红
            UIColor(red: 0.10, green: 0.65, blue: 0.70, alpha: 1.0), // 青
            UIColor(red: 0.80, green: 0.55, blue: 0.15, alpha: 1.0), // 琥珀
            UIColor(red: 0.35, green: 0.45, blue: 0.85, alpha: 1.0), // 靛青
        ]
        var hash: Int = 0
        for u in name.unicodeScalars {
            hash = (hash &* 31) &+ Int(u.value)
        }
        let index = abs(hash) % palette.count
        return palette[index]
    }
}

/// 触觉震动管理器
enum Haptic {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard ServerStore.shared.hapticEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard ServerStore.shared.hapticEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    static func selection() {
        guard ServerStore.shared.hapticEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

/// 服务器连接地址、认证凭据与本地偏好持久化（UserDefaults）
final class ServerStore {
    static let shared = ServerStore()
    static let defaultBaseURL = "https://bgp.cenai.de"

    private let defaults = UserDefaults.standard

    private enum Key {
        static let baseURL = "bgopanel.baseURL"
        static let apiToken = "bgopanel.apiToken"
        static let sessionCookie = "bgopanel.sessionCookie"
        static let hapticEnabled = "bgopanel.hapticEnabled"
        static let roomSortMode = "bgopanel.roomSortMode" // "status" (default) or "created"
        static let selectedHost = "bgopanel.selectedHost" // "all", "boh", "hwsg", "boh2"
    }

    var baseURL: String {
        get {
            let val = defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL
            return val.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
            defaults.set(trimmed.isEmpty ? Self.defaultBaseURL : trimmed, forKey: Key.baseURL)
        }
    }

    /// Bearer API Token (形如 "bgp_...")
    var apiToken: String? {
        get { defaults.string(forKey: Key.apiToken) }
        set { defaults.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apiToken) }
    }

    /// 会话 Cookie（形如 "bgo_panel_session=..."，给 Web 兜底用）
    var sessionCookie: String? {
        get { defaults.string(forKey: Key.sessionCookie) }
        set { defaults.set(newValue, forKey: Key.sessionCookie) }
    }

    var hapticEnabled: Bool {
        get { defaults.object(forKey: Key.hapticEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.hapticEnabled) }
    }

    /// 排序模式：status（状态加权：录制>监听>停止）或 created（添加顺序）
    var roomSortMode: String {
        get { defaults.string(forKey: Key.roomSortMode) ?? "status" }
        set { defaults.set(newValue, forKey: Key.roomSortMode) }
    }

    /// 当前选中的服务器节点过滤
    var selectedHost: String {
        get { defaults.string(forKey: Key.selectedHost) ?? "all" }
        set { defaults.set(newValue, forKey: Key.selectedHost) }
    }

    var hasCredentials: Bool {
        !(apiToken ?? "").isEmpty || !(sessionCookie ?? "").isEmpty
    }

    func clearCredentials() {
        defaults.removeObject(forKey: Key.apiToken)
        defaults.removeObject(forKey: Key.sessionCookie)
    }
}

/// 拦截 302 重定向：未登录时服务端对页面回 302，跟过去只会拿到登录页 HTML；客户端需拦截拿到真实状态码
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 拒绝跟随重定向，将 302/301 暴露给客户端判断
        completionHandler(nil)
    }
}

/// 头像等图片轻量级双层缓存（内存 NSCache + URLCache）
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 300
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        ]
        session = URLSession(configuration: config)
    }

    static func normalizedURLString(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("//") {
            s = "https:" + s
        } else if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        }
        return s
    }

    func load(from urlString: String?, completion: @escaping (UIImage?) -> Void) {
        guard let norm = Self.normalizedURLString(urlString), let url = URL(string: norm) else {
            completion(nil)
            return
        }

        let key = NSString(string: norm)
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.cache.setObject(img, forKey: key)
            DispatchQueue.main.async { completion(img) }
        }.resume()
    }
}
