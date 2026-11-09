import UIKit

final class LoginViewController: UIViewController {

    var onAuthenticated: (() -> Void)?

    private let store = ServerStore.shared
    private let client = APIClient.shared

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private let serverField = UITextField()
    private let segmentedControl = UISegmentedControl(items: ["API Token 认证 (推荐)", "密码登录"])
    private let tokenField = UITextField()
    private let passwordField = UITextField()
    private let tipLabel = UILabel()

    private let connectButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.background
        setupUI()
        loadCurrentSettings()
    }

    private func setupUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(container)

        // 标题区
        titleLabel.text = "bgo.panel"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.textAlignment = .center

        subtitleLabel.text = "bililive-go 独立监控面板客户端"
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.textAlignment = .center

        // 输入框通用样式
        [serverField, tokenField, passwordField].forEach {
            $0.backgroundColor = Theme.cardBackground
            $0.textColor = Theme.textPrimary
            $0.font = .systemFont(ofSize: 15)
            $0.layer.cornerRadius = 10
            $0.layer.borderWidth = 1
            $0.layer.borderColor = Theme.border.cgColor
            $0.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 10))
            $0.leftViewMode = .always
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
        }

        serverField.placeholder = "服务器地址 (默认 https://bgp.cenai.de)"
        serverField.keyboardType = .URL

        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)

        tokenField.placeholder = "API Token (格式如 bgp_...)"
        tokenField.isSecureTextEntry = false

        passwordField.placeholder = "面板登录密码"
        passwordField.isSecureTextEntry = true
        passwordField.isHidden = true

        tipLabel.text = "提示：在 Web 面板「设置」页可一键生成永久 API Token，支持快捷免密连接。"
        tipLabel.font = .systemFont(ofSize: 12)
        tipLabel.textColor = Theme.textMuted
        tipLabel.numberOfLines = 0

        // 连接按钮
        connectButton.setTitle("测试并连接", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        connectButton.backgroundColor = Theme.listeningGreen
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(handleConnect), for: .touchUpInside)

        spinner.color = .white
        spinner.hidesWhenStopped = true

        errorLabel.textColor = Theme.recordingRed
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        [titleLabel, subtitleLabel, serverField, segmentedControl, tokenField, passwordField, tipLabel, connectButton, spinner, errorLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            container.topAnchor.constraint(equalTo: scroll.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            serverField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 36),
            serverField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            serverField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            serverField.heightAnchor.constraint(equalToConstant: 48),

            segmentedControl.topAnchor.constraint(equalTo: serverField.bottomAnchor, constant: 18),
            segmentedControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            segmentedControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            tokenField.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 14),
            tokenField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            tokenField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            tokenField.heightAnchor.constraint(equalToConstant: 48),

            passwordField.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 14),
            passwordField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            passwordField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            passwordField.heightAnchor.constraint(equalToConstant: 48),

            tipLabel.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 10),
            tipLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            tipLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),

            connectButton.topAnchor.constraint(equalTo: tipLabel.bottomAnchor, constant: 28),
            connectButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            connectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            connectButton.heightAnchor.constraint(equalToConstant: 48),

            spinner.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: connectButton.trailingAnchor, constant: -16),

            errorLabel.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 14),
            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            errorLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -30)
        ])
    }

    private func loadCurrentSettings() {
        serverField.text = store.baseURL
        if let token = store.apiToken, !token.isEmpty {
            tokenField.text = token
            segmentedControl.selectedSegmentIndex = 0
            tokenField.isHidden = false
            passwordField.isHidden = true
        }
    }

    @objc private func segmentChanged() {
        Haptic.selection()
        let isToken = segmentedControl.selectedSegmentIndex == 0
        tokenField.isHidden = !isToken
        passwordField.isHidden = isToken
        tipLabel.text = isToken
            ? "提示：在 Web 面板「设置」页可一键生成永久 API Token，支持快捷免密连接。"
            : "提示：使用面板主登录密码，验证成功后将保持会话 7 天。"
        errorLabel.isHidden = true
    }

    @objc private func handleConnect() {
        view.endEditing(true)
        Haptic.impact(.light)

        let serverText = (serverField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        store.baseURL = serverText.isEmpty ? ServerStore.defaultBaseURL : serverText

        errorLabel.isHidden = true
        spinner.startAnimating()
        connectButton.isEnabled = false

        Task {
            do {
                if segmentedControl.selectedSegmentIndex == 0 {
                    // API Token 模式
                    let token = (tokenField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else {
                        throw APIError.server("请输入 API Token")
                    }
                    store.apiToken = token
                    let ok = try await client.testConnection()
                    guard ok else {
                        throw APIError.unauthorized
                    }
                } else {
                    // 密码模式
                    let pw = passwordField.text ?? ""
                    guard !pw.isEmpty else {
                        throw APIError.server("请输入面板登录密码")
                    }
                    _ = try await client.login(password: pw)
                }

                await MainActor.run {
                    spinner.stopAnimating()
                    connectButton.isEnabled = true
                    Haptic.notification(.success)
                    AppLog.info("连接验证成功！")
                    if let callback = onAuthenticated {
                        callback()
                    } else {
                        dismiss(animated: true)
                    }
                }
            } catch {
                await MainActor.run {
                    spinner.stopAnimating()
                    connectButton.isEnabled = true
                    Haptic.notification(.error)
                    errorLabel.text = error.localizedDescription
                    errorLabel.isHidden = false
                }
            }
        }
    }
}
