import UIKit
import WebKit

/// 完整站点兜底控制器：备援配置、操作日志、磁盘图表等高级功能的内嵌 WebView 容器
final class WebViewController: UIViewController, WKNavigationDelegate {

    private let path: String
    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()

    init(path: String, title: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.background
        buildUI()
        load()
    }

    private func buildUI() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "BgoPanelApp/1.0 (iOS)"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = Theme.background
        webView.scrollView.backgroundColor = Theme.background
        webView.translatesAutoresizingMaskIntoConstraints = false

        let bar = UIView()
        bar.backgroundColor = Theme.cardBackground
        bar.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = Theme.textPrimary
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let reloadButton = UIButton(type: .system)
        reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton.tintColor = Theme.textPrimary
        reloadButton.addTarget(self, action: #selector(reload), for: .touchUpInside)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.textAlignment = .center

        spinner.color = .white
        spinner.hidesWhenStopped = true

        [closeButton, titleLabel, reloadButton, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        view.addSubview(bar)
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),

            closeButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            closeButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),

            reloadButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            reloadButton.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),

            spinner.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: reloadButton.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),

            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func load() {
        let store = ServerStore.shared
        guard let url = URL(string: "\(store.baseURL)\(path)") else { return }

        // 注入当前会话 Cookie
        if let cookieStr = store.sessionCookie,
           let host = url.host {
            let parts = cookieStr.components(separatedBy: "=")
            if parts.count >= 2 {
                let name = parts[0]
                let value = parts[1...].joined(separator: "=")
                if let cookie = HTTPCookie(properties: [
                    .domain: host,
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE"
                ]) {
                    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
        }

        var req = URLRequest(url: url)
        if let token = store.apiToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        spinner.startAnimating()
        webView.load(req)
    }

    @objc private func close() {
        Haptic.impact(.light)
        dismiss(animated: true)
    }

    @objc private func reload() {
        Haptic.impact(.light)
        spinner.startAnimating()
        webView.reload()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
}
