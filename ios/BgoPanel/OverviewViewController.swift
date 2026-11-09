import UIKit

final class OverviewViewController: UIViewController {

    private let client = APIClient.shared
    private let refreshControl = UIRefreshControl()

    private let recordingValueLabel = UILabel()
    private let listeningValueLabel = UILabel()
    private let totalValueLabel = UILabel()
    private let failoverValueLabel = UILabel()

    private let hostsStackView = UIStackView()
    private var isRefreshing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.background
        navigationItem.title = "运行总览"

        setupUI()
        loadOverview()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadOverview(silent: true)
    }

    private func setupUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        refreshControl.tintColor = Theme.textSecondary
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        scroll.refreshControl = refreshControl
        view.addSubview(scroll)

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(container)

        // 2x2 KPI 指标卡
        let cardRec = makeKpiCard(title: "正在录制", valueLabel: recordingValueLabel, color: Theme.recordingRed)
        let cardLis = makeKpiCard(title: "正在监听", valueLabel: listeningValueLabel, color: Theme.listeningGreen)
        let cardTot = makeKpiCard(title: "监控总数", valueLabel: totalValueLabel, color: Theme.textPrimary)
        let cardFo = makeKpiCard(title: "备援状态", valueLabel: failoverValueLabel, color: Theme.warningYellow)

        let row1 = UIStackView(arrangedSubviews: [cardRec, cardLis])
        row1.axis = .horizontal
        row1.distribution = .fillEqually
        row1.spacing = 12

        let row2 = UIStackView(arrangedSubviews: [cardTot, cardFo])
        row2.axis = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 12

        let kpiStack = UIStackView(arrangedSubviews: [row1, row2])
        kpiStack.axis = .vertical
        kpiStack.spacing = 12

        // 服务器节点分区
        let hostsSectionTitle = UILabel()
        hostsSectionTitle.text = "服务器节点 (Hosts)"
        hostsSectionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        hostsSectionTitle.textColor = Theme.textSecondary

        hostsStackView.axis = .vertical
        hostsStackView.spacing = 8

        // 快速跳转卡片
        let quickSectionTitle = UILabel()
        quickSectionTitle.text = "快速直达"
        quickSectionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        quickSectionTitle.textColor = Theme.textSecondary

        let btnFo = makeActionRow(icon: "shield.checkered", title: "备援与接管规则", subtitle: "查看 boh2 备援配置与触发阈值") { [weak self] in
            let web = WebViewController(path: "/#failover", title: "备援规则")
            self?.present(web, animated: true)
        }

        let btnOplog = makeActionRow(icon: "list.bullet.rectangle", title: "运行与审计日志", subtitle: "查看面板与自动规则操作日志") { [weak self] in
            let web = WebViewController(path: "/#oplog", title: "操作日志")
            self?.present(web, animated: true)
        }

        let quickStack = UIStackView(arrangedSubviews: [btnFo, btnOplog])
        quickStack.axis = .vertical
        quickStack.spacing = 8

        [kpiStack, hostsSectionTitle, hostsStackView, quickSectionTitle, quickStack].forEach {
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

            kpiStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            kpiStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            kpiStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            hostsSectionTitle.topAnchor.constraint(equalTo: kpiStack.bottomAnchor, constant: 24),
            hostsSectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            hostsStackView.topAnchor.constraint(equalTo: hostsSectionTitle.bottomAnchor, constant: 8),
            hostsStackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hostsStackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            quickSectionTitle.topAnchor.constraint(equalTo: hostsStackView.bottomAnchor, constant: 24),
            quickSectionTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            quickStack.topAnchor.constraint(equalTo: quickSectionTitle.bottomAnchor, constant: 8),
            quickStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            quickStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            quickStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -30)
        ])
    }

    private func makeKpiCard(title: String, valueLabel: UILabel, color: UIColor) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.cardBackground
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.border.cgColor

        let tLbl = UILabel()
        tLbl.text = title
        tLbl.font = .systemFont(ofSize: 12, weight: .medium)
        tLbl.textColor = Theme.textSecondary

        valueLabel.text = "--"
        valueLabel.font = .systemFont(ofSize: 26, weight: .bold)
        valueLabel.textColor = color

        [tLbl, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        NSLayoutConstraint.activate([
            tLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            tLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),

            valueLabel.topAnchor.constraint(equalTo: tLbl.bottomAnchor, constant: 6),
            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            valueLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func makeActionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> UIView {
        let btn = UIButton(type: .system)
        btn.backgroundColor = Theme.cardBackground
        btn.layer.cornerRadius = 10
        btn.layer.borderWidth = 1
        btn.layer.borderColor = Theme.border.cgColor

        let imgView = UIImageView(image: UIImage(systemName: icon))
        imgView.tintColor = Theme.listeningGreen
        imgView.contentMode = .scaleAspectFit

        let tLbl = UILabel()
        tLbl.text = title
        tLbl.font = .systemFont(ofSize: 14, weight: .semibold)
        tLbl.textColor = Theme.textPrimary

        let subLbl = UILabel()
        subLbl.text = subtitle
        subLbl.font = .systemFont(ofSize: 11)
        subLbl.textColor = Theme.textSecondary

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Theme.textMuted

        let vStack = UIStackView(arrangedSubviews: [tLbl, subLbl])
        vStack.axis = .vertical
        vStack.spacing = 2

        [imgView, vStack, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            btn.addSubview($0)
        }

        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 58),

            imgView.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 14),
            imgView.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 24),
            imgView.heightAnchor.constraint(equalToConstant: 24),

            vStack.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
            vStack.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            vStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12)
        ])

        btn.addAction(UIAction { _ in
            Haptic.impact(.light)
            action()
        }, for: .touchUpInside)

        return btn
    }

    // MARK: - 数据加载

    @objc private func handleRefresh() {
        Haptic.impact(.light)
        loadOverview()
    }

    private func loadOverview(silent: Bool = false) {
        if isRefreshing { return }
        isRefreshing = true

        Task {
            async let fetchCountsTask = client.fetchOverview()
            async let fetchHostsTask = client.fetchHosts()

            do {
                let (counts, hosts) = try await (fetchCountsTask, fetchHostsTask)
                await MainActor.run {
                    self.recordingValueLabel.text = "\(counts.recording)"
                    self.listeningValueLabel.text = "\(counts.listening)"
                    self.totalValueLabel.text = "\(counts.total)"
                    self.failoverValueLabel.text = "待命中" // boh2 常驻待命

                    self.updateHostsUI(hosts)
                    self.refreshControl.endRefreshing()
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    self.isRefreshing = false
                    if !silent {
                        AppLog.error("加载总览失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func updateHostsUI(_ hosts: [HostItem]) {
        hostsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for h in hosts {
            let row = UIView()
            row.backgroundColor = Theme.cardBackground
            row.layer.cornerRadius = 8
            row.layer.borderWidth = 1
            row.layer.borderColor = Theme.border.cgColor

            let dot = UIView()
            dot.backgroundColor = h.ok ? Theme.listeningGreen : Theme.recordingRed
            dot.layer.cornerRadius = 5

            let nameLbl = UILabel()
            nameLbl.text = h.local ? "\(h.name) (主集群)" : h.name
            nameLbl.font = .systemFont(ofSize: 13, weight: .semibold)
            nameLbl.textColor = Theme.textPrimary

            let statsLbl = UILabel()
            statsLbl.text = h.ok ? "在录 \(h.recording) · 监听 \(h.listening) · 共 \(h.total)" : (h.error ?? "连接超时")
            statsLbl.font = .systemFont(ofSize: 11)
            statsLbl.textColor = h.ok ? Theme.textSecondary : Theme.recordingRed
            statsLbl.textAlignment = .right

            [dot, nameLbl, statsLbl].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview($0)
            }

            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 44),

                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 10),
                dot.heightAnchor.constraint(equalToConstant: 10),

                nameLbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
                nameLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

                statsLbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                statsLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                statsLbl.leadingAnchor.constraint(greaterThanOrEqualTo: nameLbl.trailingAnchor, constant: 8)
            ])

            hostsStackView.addArrangedSubview(row)
        }
    }
}
