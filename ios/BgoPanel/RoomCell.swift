import UIKit

final class RoomCell: UITableViewCell {
    static let reuseIdentifier = "RoomCell"

    var onToggleListening: (() -> Void)?

    private let avatarContainer = UIView()
    private let avatarLabel = UILabel()
    private let avatarImageView = UIImageView()
    private let nameLabel = UILabel()
    private let hostBadgeLabel = UILabel()
    private let scoreBadgeLabel = UILabel()
    private let titleLabel = UILabel()
    private let modeBadgeLabel = UILabel()
    private let statusLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var currentAvatarUrl: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = Theme.cardBackground
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private func setupUI() {
        contentView.backgroundColor = Theme.cardBackground

        avatarContainer.layer.cornerRadius = 22
        avatarContainer.layer.masksToBounds = true
        avatarContainer.backgroundColor = Theme.cardSelected
        avatarContainer.layer.borderWidth = 1.5
        avatarContainer.layer.borderColor = Theme.border.cgColor

        avatarLabel.font = .systemFont(ofSize: 18, weight: .bold)
        avatarLabel.textColor = .white
        avatarLabel.textAlignment = .center
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.addSubview(avatarLabel)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.isHidden = true
        avatarContainer.addSubview(avatarImageView)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary

        hostBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        hostBadgeLabel.textColor = Theme.textMuted
        hostBadgeLabel.backgroundColor = Theme.background
        hostBadgeLabel.layer.cornerRadius = 4
        hostBadgeLabel.layer.masksToBounds = true
        hostBadgeLabel.textAlignment = .center

        scoreBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        scoreBadgeLabel.textColor = Theme.scoreGold
        scoreBadgeLabel.backgroundColor = UIColor(red: 0.25, green: 0.20, blue: 0.05, alpha: 1.0)
        scoreBadgeLabel.layer.cornerRadius = 4
        scoreBadgeLabel.layer.masksToBounds = true
        scoreBadgeLabel.textAlignment = .center

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = Theme.textSecondary
        titleLabel.numberOfLines = 1

        modeBadgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modeBadgeLabel.textColor = .white
        modeBadgeLabel.layer.cornerRadius = 4
        modeBadgeLabel.layer.masksToBounds = true
        modeBadgeLabel.textAlignment = .center

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        toggleButton.setImage(UIImage(systemName: "power"), for: .normal)
        toggleButton.tintColor = Theme.textSecondary
        toggleButton.backgroundColor = Theme.cardSelected
        toggleButton.layer.cornerRadius = 16
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [nameLabel, hostBadgeLabel, scoreBadgeLabel, UIView()])
        topRow.axis = .horizontal
        topRow.spacing = 6
        topRow.alignment = .center

        let bottomRow = UIStackView(arrangedSubviews: [modeBadgeLabel, statusLabel, UIView()])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .center

        let middleCol = UIStackView(arrangedSubviews: [topRow, titleLabel, bottomRow])
        middleCol.axis = .vertical
        middleCol.spacing = 3

        [avatarContainer, middleCol, toggleButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            avatarLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),

            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),

            avatarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            avatarContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarContainer.widthAnchor.constraint(equalToConstant: 44),
            avatarContainer.heightAnchor.constraint(equalToConstant: 44),

            toggleButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            toggleButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 32),
            toggleButton.heightAnchor.constraint(equalToConstant: 32),

            middleCol.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
            middleCol.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -10),
            middleCol.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            middleCol.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            hostBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            hostBadgeLabel.heightAnchor.constraint(equalToConstant: 16),

            scoreBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            scoreBadgeLabel.heightAnchor.constraint(equalToConstant: 18),

            modeBadgeLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAvatarUrl = nil
        avatarImageView.image = nil
        avatarImageView.isHidden = true
        avatarLabel.isHidden = false
    }

    func configure(with room: Room, score: StreamerScore?) {
        nameLabel.text = room.streamerName
        titleLabel.text = (room.title?.isEmpty ?? true) ? "（暂无标题）" : room.title

        hostBadgeLabel.text = " \(room.host) "
        statusLabel.text = room.statusText
        statusLabel.textColor = room.statusColor

        // 默认显示主播名字首字与专属彩色背景（优雅降级）
        avatarLabel.text = Theme.initial(room.streamerName)
        avatarContainer.backgroundColor = Theme.avatarColor(for: room.streamerName)
        avatarLabel.isHidden = false
        avatarImageView.image = nil
        avatarImageView.isHidden = true

        // 录制中头像加红圈，监听中加绿圈
        if room.recording {
            avatarContainer.layer.borderColor = Theme.recordingRed.cgColor
            avatarContainer.layer.borderWidth = 2.0
            toggleButton.tintColor = Theme.recordingRed
        } else if room.listening {
            avatarContainer.layer.borderColor = Theme.listeningGreen.cgColor
            avatarContainer.layer.borderWidth = 1.5
            toggleButton.tintColor = Theme.listeningGreen
        } else {
            avatarContainer.layer.borderColor = Theme.border.cgColor
            avatarContainer.layer.borderWidth = 1.0
            toggleButton.tintColor = Theme.textMuted
        }

        // 模式徽章
        modeBadgeLabel.text = " \(room.modeBadgeText) "
        modeBadgeLabel.backgroundColor = room.modeBadgeColor

        // dyzb 评分
        if let s = score, let avg = s.avgScore, avg > 0 {
            scoreBadgeLabel.text = String(format: " ⭐ %.1f ", avg)
            scoreBadgeLabel.isHidden = false
        } else {
            scoreBadgeLabel.isHidden = true
        }

        // 若有真实图片头像则异步加载并覆盖
        let normUrl = ImageLoader.normalizedURLString(room.avatar)
        currentAvatarUrl = normUrl
        if let avatarUrl = normUrl {
            ImageLoader.shared.load(from: avatarUrl) { [weak self] img in
                guard let self = self, self.currentAvatarUrl == avatarUrl, let img = img else { return }
                self.avatarImageView.image = img
                self.avatarImageView.isHidden = false
                self.avatarLabel.isHidden = true
            }
        }
    }

    @objc private func toggleTapped() {
        Haptic.impact(.light)
        onToggleListening?()
    }
}
