import UIKit

final class RoomCell: UITableViewCell {
    static let reuseIdentifier = "RoomCell"

    var onToggleListening: (() -> Void)?

    private let avatarImageView = UIImageView()
    private let nameLabel = UILabel()
    private let hostBadgeLabel = UILabel()
    private let scoreBadgeLabel = UILabel()
    private let titleLabel = UILabel()
    private let modeBadgeLabel = UILabel()
    private let statusLabel = UILabel()
    private let toggleButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = Theme.cardBackground
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private func setupUI() {
        contentView.backgroundColor = Theme.cardBackground

        avatarImageView.layer.cornerRadius = 22
        avatarImageView.layer.masksToBounds = true
        avatarImageView.backgroundColor = Theme.cardSelected
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.layer.borderWidth = 1.5
        avatarImageView.layer.borderColor = Theme.border.cgColor

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

        [avatarImageView, middleCol, toggleButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            avatarImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 44),
            avatarImageView.heightAnchor.constraint(equalToConstant: 44),

            toggleButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            toggleButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 32),
            toggleButton.heightAnchor.constraint(equalToConstant: 32),

            middleCol.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
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

    func configure(with room: Room, score: StreamerScore?) {
        nameLabel.text = room.streamerName
        titleLabel.text = (room.title?.isEmpty ?? true) ? "（暂无标题）" : room.title

        hostBadgeLabel.text = " \(room.host) "
        statusLabel.text = room.statusText
        statusLabel.textColor = room.statusColor

        // 录制中头像加红圈
        if room.recording {
            avatarImageView.layer.borderColor = Theme.recordingRed.cgColor
            avatarImageView.layer.borderWidth = 2.0
            toggleButton.tintColor = Theme.recordingRed
        } else if room.listening {
            avatarImageView.layer.borderColor = Theme.listeningGreen.cgColor
            avatarImageView.layer.borderWidth = 1.5
            toggleButton.tintColor = Theme.listeningGreen
        } else {
            avatarImageView.layer.borderColor = Theme.border.cgColor
            avatarImageView.layer.borderWidth = 1.0
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

        // 头像加载
        avatarImageView.image = UIImage(systemName: "person.circle.fill")
        avatarImageView.tintColor = Theme.textMuted
        if let avatarUrl = room.avatar, !avatarUrl.isEmpty {
            ImageLoader.shared.load(from: avatarUrl) { [weak self] img in
                if let img = img {
                    self?.avatarImageView.image = img
                }
            }
        }
    }

    @objc private func toggleTapped() {
        Haptic.impact(.light)
        onToggleListening?()
    }
}
