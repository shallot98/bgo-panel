import UIKit

final class AddRoomViewController: UIViewController {

    var onRoomAdded: (() -> Void)?

    private let client = APIClient.shared

    private let titleLabel = UILabel()
    private let pasteHintLabel = UILabel()
    private let inputTextView = UITextView()

    private let modeSegment = UISegmentedControl(items: ["永久", "临时 24h", "只录本场", "自定义"])
    private let customParamField = UITextField()

    private let hostSegment = UISegmentedControl(items: ["boh (主)", "boh2 (备援)", "hwsg"])

    private let submitButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.cardBackground
        setupUI()
        checkClipboard()
    }

    private func setupUI() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = Theme.textPrimary
        closeBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        titleLabel.text = "添加监控房间"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.textAlignment = .center

        [closeBtn, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        view.addSubview(bar)

        // 剪贴板自动抓取提示
        pasteHintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pasteHintLabel.textColor = Theme.listeningGreen
        pasteHintLabel.text = "已从剪贴板自动提取抖音分享内容"
        pasteHintLabel.isHidden = true

        // 输入框
        inputTextView.backgroundColor = Theme.background
        inputTextView.textColor = Theme.textPrimary
        inputTextView.font = .systemFont(ofSize: 14)
        inputTextView.layer.cornerRadius = 8
        inputTextView.layer.borderWidth = 1
        inputTextView.layer.borderColor = Theme.border.cgColor
        inputTextView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        // 模式选择
        modeSegment.selectedSegmentIndex = 0
        modeSegment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        customParamField.backgroundColor = Theme.background
        customParamField.textColor = Theme.textPrimary
        customParamField.font = .systemFont(ofSize: 14)
        customParamField.layer.cornerRadius = 8
        customParamField.layer.borderWidth = 1
        customParamField.layer.borderColor = Theme.border.cgColor
        customParamField.placeholder = "小时数 (如 12) 或 场数 (如 3)"
        customParamField.keyboardType = .numberPad
        customParamField.isHidden = true

        // 节点选择
        hostSegment.selectedSegmentIndex = 0

        // 提交按钮
        submitButton.setTitle("立即添加", for: .normal)
        submitButton.setTitleColor(.white, for: .normal)
        submitButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        submitButton.backgroundColor = Theme.listeningGreen
        submitButton.layer.cornerRadius = 10
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        spinner.color = .white
        spinner.hidesWhenStopped = true

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = Theme.recordingRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true

        let modeSectionTitle = makeSectionTitle("监控模式")
        let hostSectionTitle = makeSectionTitle("目标服务器")

        [bar, pasteHintLabel, inputTextView, modeSectionTitle, modeSegment, customParamField, hostSectionTitle, hostSegment, submitButton, spinner, errorLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            closeBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            closeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pasteHintLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            pasteHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            pasteHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            inputTextView.topAnchor.constraint(equalTo: pasteHintLabel.bottomAnchor, constant: 6),
            inputTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            inputTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            inputTextView.heightAnchor.constraint(equalToConstant: 90),

            modeSectionTitle.topAnchor.constraint(equalTo: inputTextView.bottomAnchor, constant: 16),
            modeSectionTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            modeSegment.topAnchor.constraint(equalTo: modeSectionTitle.bottomAnchor, constant: 8),
            modeSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            modeSegment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            customParamField.topAnchor.constraint(equalTo: modeSegment.bottomAnchor, constant: 8),
            customParamField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            customParamField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            customParamField.heightAnchor.constraint(equalToConstant: 40),

            hostSectionTitle.topAnchor.constraint(equalTo: customParamField.bottomAnchor, constant: 14),
            hostSectionTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            hostSegment.topAnchor.constraint(equalTo: hostSectionTitle.bottomAnchor, constant: 8),
            hostSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hostSegment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            submitButton.topAnchor.constraint(equalTo: hostSegment.bottomAnchor, constant: 24),
            submitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            submitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            submitButton.heightAnchor.constraint(equalToConstant: 46),

            spinner.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: submitButton.trailingAnchor, constant: -16),

            errorLabel.topAnchor.constraint(equalTo: submitButton.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let lbl = UILabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = Theme.textSecondary
        return lbl
    }

    private func checkClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        if text.contains("douyin.com") || text.range(of: "^[0-9]{8,15}$", options: .regularExpression) != nil {
            inputTextView.text = text
            pasteHintLabel.isHidden = false
            Haptic.notification(.success)
        }
    }

    @objc private func modeChanged() {
        Haptic.selection()
        let isCustom = modeSegment.selectedSegmentIndex == 3
        customParamField.isHidden = !isCustom
    }

    @objc private func cancelTapped() {
        Haptic.impact(.light)
        dismiss(animated: true)
    }

    @objc private func submitTapped() {
        view.endEditing(true)
        Haptic.impact(.medium)

        let text = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorLabel.text = "请输入房间号、分享链接或完整文案"
            errorLabel.isHidden = false
            return
        }

        var mode = "permanent"
        switch modeSegment.selectedSegmentIndex {
        case 0: mode = "permanent"
        case 1: mode = "24" // 临时 24 小时
        case 2: mode = "1"  // 只录 1 场
        case 3:
            let custom = customParamField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            mode = custom.isEmpty ? "permanent" : custom
        default: break
        }

        let hostChoices = ["boh", "boh2", "hwsg"]
        let host = hostChoices[hostSegment.selectedSegmentIndex]

        spinner.startAnimating()
        submitButton.isEnabled = false
        errorLabel.isHidden = true

        Task {
            do {
                let msg = try await client.addRoom(urlOrText: text, mode: mode, host: host)
                await MainActor.run {
                    spinner.stopAnimating()
                    submitButton.isEnabled = true
                    Haptic.notification(.success)
                    AppLog.info("加房成功: \(msg)")
                    onRoomAdded?()
                    dismiss(animated: true)
                }
            } catch {
                await MainActor.run {
                    spinner.stopAnimating()
                    submitButton.isEnabled = true
                    Haptic.notification(.error)
                    errorLabel.text = error.localizedDescription
                    errorLabel.isHidden = false
                }
            }
        }
    }
}
