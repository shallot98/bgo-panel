import UIKit

final class MoreViewController: UIViewController {

    private let store = ServerStore.shared

    private let serverAddressLabel = UILabel()
    private let authStatusLabel = UILabel()
    private let hapticSwitch = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.background
        navigationItem.title = "控制台与设置"

        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateStatusLabels()
    }

    private func setupUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(container)

        // Section 1: 运维控制台
        let sec1Title = makeSectionHeader("运维控制台 (完整 Web 兜底)")
        let btnFo = makeNavRow(icon: "shield.checkered", title: "备援与自动接管规则") { [weak self] in
            let web = WebViewController(path: "/#failover", title: "备援配置")
            self?.present(web, animated: true)
        }
        let btnOplog = makeNavRow(icon: "list.bullet.rectangle", title: "操作与审计日志") { [weak self] in
            let web = WebViewController(path: "/#oplog", title: "操作日志")
            self?.present(web, animated: true)
        }
        let btnStorage = makeNavRow(icon: "internaldrive", title: "存储空间与网盘转运") { [weak self] in
            let web = WebViewController(path: "/#storage", title: "存储管理")
            self?.present(web, animated: true)
        }
        let btnHealth = makeNavRow(icon: "waveform.path.ecg", title: "系统健康与出口体检") { [weak self] in
            let web = WebViewController(path: "/#health", title: "健康状态")
            self?.present(web, animated: true)
        }
        let btnPassword = makeNavRow(icon: "lock.shield", title: "修改面板登录密码") { [weak self] in
            let web = WebViewController(path: "/#settings", title: "修改密码")
            self?.present(web, animated: true)
        }

        let stack1 = UIStackView(arrangedSubviews: [btnFo, btnOplog, btnStorage, btnHealth, btnPassword])
        stack1.axis = .vertical
        stack1.spacing = 8

        // Section 2: 本地客户端设置
        let sec2Title = makeSectionHeader("本地客户端设置")

        let serverRow = makeInfoRow(title: "当前连接服务器", valueLabel: serverAddressLabel)
        let authRow = makeInfoRow(title: "认证状态", valueLabel: authStatusLabel)

        let reAuthBtn = makeNavRow(icon: "key", title: "重新配置服务器与 Token") { [weak self] in
            let loginVC = LoginViewController()
            loginVC.onAuthenticated = { [weak self] in
                self?.updateStatusLabels()
                loginVC.dismiss(animated: true)
            }
            self?.present(loginVC, animated: true)
        }

        let hapticRow = makeSwitchRow(title: "触觉震动反馈", switchControl: hapticSwitch)
        hapticSwitch.isOn = store.hapticEnabled
        hapticSwitch.addTarget(self, action: #selector(hapticToggled), for: .valueChanged)

        let clearCacheBtn = makeNavRow(icon: "trash", title: "清理本地图片缓存") { [weak self] in
            Haptic.notification(.success)
            let alert = UIAlertController(title: nil, message: "本地缓存已清空", preferredStyle: .alert)
            self?.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                alert.dismiss(animated: true)
            }
        }

        let stack2 = UIStackView(arrangedSubviews: [serverRow, authRow, reAuthBtn, hapticRow, clearCacheBtn])
        stack2.axis = .vertical
        stack2.spacing = 8

        // Section 3: 关于
        let sec3Title = makeSectionHeader("关于")
        let aboutCard = UIView()
        aboutCard.backgroundColor = Theme.cardBackground
        aboutCard.layer.cornerRadius = 10
        aboutCard.layer.borderWidth = 1
        aboutCard.layer.borderColor = Theme.border.cgColor

        let appNameLbl = UILabel()
        appNameLbl.text = "bgo面板 iOS 客户端"
        appNameLbl.font = .systemFont(ofSize: 14, weight: .semibold)
        appNameLbl.textColor = Theme.textPrimary

        let verLbl = UILabel()
        verLbl.text = "v1.0.0 (Build 1) · 纯 Swift 原生"
        verLbl.font = .systemFont(ofSize: 12)
        verLbl.textColor = Theme.textSecondary

        let vStack = UIStackView(arrangedSubviews: [appNameLbl, verLbl])
        vStack.axis = .vertical
        vStack.spacing = 4

        vStack.translatesAutoresizingMaskIntoConstraints = false
        aboutCard.addSubview(vStack)
        NSLayoutConstraint.activate([
            aboutCard.heightAnchor.constraint(equalToConstant: 60),
            vStack.leadingAnchor.constraint(equalTo: aboutCard.leadingAnchor, constant: 14),
            vStack.centerYAnchor.constraint(equalTo: aboutCard.centerYAnchor)
        ])

        [sec1Title, stack1, sec2Title, stack2, sec3Title, aboutCard].forEach {
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

            sec1Title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            sec1Title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            stack1.topAnchor.constraint(equalTo: sec1Title.bottomAnchor, constant: 8),
            stack1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            sec2Title.topAnchor.constraint(equalTo: stack1.bottomAnchor, constant: 24),
            sec2Title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            stack2.topAnchor.constraint(equalTo: sec2Title.bottomAnchor, constant: 8),
            stack2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            sec3Title.topAnchor.constraint(equalTo: stack2.bottomAnchor, constant: 24),
            sec3Title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            aboutCard.topAnchor.constraint(equalTo: sec3Title.bottomAnchor, constant: 8),
            aboutCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            aboutCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            aboutCard.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -30)
        ])
    }

    private func updateStatusLabels() {
        serverAddressLabel.text = store.baseURL
        if let tok = store.apiToken, !tok.isEmpty {
            authStatusLabel.text = "API Token 已绑定"
            authStatusLabel.textColor = Theme.listeningGreen
        } else if let cookie = store.sessionCookie, !cookie.isEmpty {
            authStatusLabel.text = "密码会话已连接"
            authStatusLabel.textColor = Theme.listeningGreen
        } else {
            authStatusLabel.text = "未配置凭据"
            authStatusLabel.textColor = Theme.recordingRed
        }
    }

    @objc private func hapticToggled() {
        store.hapticEnabled = hapticSwitch.isOn
        Haptic.impact(.light)
    }

    private func makeSectionHeader(_ title: String) -> UILabel {
        let lbl = UILabel()
        lbl.text = title
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = Theme.textSecondary
        return lbl
    }

    private func makeNavRow(icon: String, title: String, action: @escaping () -> Void) -> UIView {
        let btn = UIButton(type: .system)
        btn.backgroundColor = Theme.cardBackground
        btn.layer.cornerRadius = 10
        btn.layer.borderWidth = 1
        btn.layer.borderColor = Theme.border.cgColor

        let imgView = UIImageView(image: UIImage(systemName: icon))
        imgView.tintColor = Theme.textPrimary
        imgView.contentMode = .scaleAspectFit

        let tLbl = UILabel()
        tLbl.text = title
        tLbl.font = .systemFont(ofSize: 14, weight: .medium)
        tLbl.textColor = Theme.textPrimary

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Theme.textMuted

        [imgView, tLbl, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            btn.addSubview($0)
        }

        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 48),

            imgView.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 14),
            imgView.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 20),
            imgView.heightAnchor.constraint(equalToConstant: 20),

            tLbl.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
            tLbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: btn.centerYAnchor)
        ])

        btn.addAction(UIAction { _ in
            Haptic.impact(.light)
            action()
        }, for: .touchUpInside)

        return btn
    }

    private func makeInfoRow(title: String, valueLabel: UILabel) -> UIView {
        let row = UIView()
        row.backgroundColor = Theme.cardBackground
        row.layer.cornerRadius = 10
        row.layer.borderWidth = 1
        row.layer.borderColor = Theme.border.cgColor

        let tLbl = UILabel()
        tLbl.text = title
        tLbl.font = .systemFont(ofSize: 14, weight: .medium)
        tLbl.textColor = Theme.textPrimary

        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.textColor = Theme.textSecondary
        valueLabel.textAlignment = .right

        [tLbl, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),

            tLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            tLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tLbl.trailingAnchor, constant: 8)
        ])
        return row
    }

    private func makeSwitchRow(title: String, switchControl: UISwitch) -> UIView {
        let row = UIView()
        row.backgroundColor = Theme.cardBackground
        row.layer.cornerRadius = 10
        row.layer.borderWidth = 1
        row.layer.borderColor = Theme.border.cgColor

        let tLbl = UILabel()
        tLbl.text = title
        tLbl.font = .systemFont(ofSize: 14, weight: .medium)
        tLbl.textColor = Theme.textPrimary

        switchControl.onTintColor = Theme.listeningGreen

        [tLbl, switchControl].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),

            tLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            tLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            switchControl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            switchControl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }
}
