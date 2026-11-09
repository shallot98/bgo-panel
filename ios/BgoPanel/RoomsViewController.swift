import UIKit

final class RoomsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let client = APIClient.shared
    private let store = ServerStore.shared

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let subtitleLabel = UILabel()

    private var allRooms: [Room] = []
    private var displayedRooms: [Room] = []
    private var scores: [String: StreamerScore] = [:]
    private var isRefreshing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Theme.background
        setupNavigation()
        setupTableView()
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData(silent: true)
    }

    private func setupNavigation() {
        navigationItem.title = "监控房间"

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = Theme.textSecondary
        subtitleLabel.textAlignment = .center
        navigationItem.titleView = subtitleLabel

        // 右上角加房按钮与排序菜单
        let addBtn = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(openAddRoom)
        )
        addBtn.tintColor = Theme.listeningGreen

        let sortBtn = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(toggleSortMode)
        )
        sortBtn.tintColor = Theme.textPrimary

        navigationItem.rightBarButtonItems = [addBtn, sortBtn]

        // 左上角节点切换菜单
        setupHostFilterMenu()
    }

    private func setupHostFilterMenu() {
        let current = store.selectedHost
        let hosts = [
            ("all", "全部节点"),
            ("boh", "boh (主集群)"),
            ("boh2", "boh2 (备援)"),
            ("hwsg", "hwsg")
        ]

        let actions = hosts.map { key, title in
            UIAction(title: title, state: current == key ? .on : .off) { [weak self] _ in
                self?.store.selectedHost = key
                self?.setupHostFilterMenu()
                self?.applyFilterAndSort()
            }
        }

        let menu = UIMenu(title: "切换服务器节点", children: actions)
        let filterBtn = UIBarButtonItem(image: UIImage(systemName: "server.rack"), menu: menu)
        filterBtn.tintColor = current == "all" ? Theme.textSecondary : Theme.listeningGreen
        navigationItem.leftBarButtonItem = filterBtn
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = Theme.border
        tableView.rowHeight = 72
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(RoomCell.self, forCellReuseIdentifier: RoomCell.reuseIdentifier)

        refreshControl.tintColor = Theme.textSecondary
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - 数据加载与处理

    @objc private func handleRefresh() {
        Haptic.impact(.light)
        loadData()
    }

    private func loadData(silent: Bool = false) {
        if isRefreshing { return }
        isRefreshing = true

        Task {
            async let fetchRoomsTask = client.fetchRooms(host: "all")
            async let fetchScoresTask = client.fetchScores()

            do {
                let (roomsResult, scoresResult) = try await (fetchRoomsTask, fetchScoresTask)
                await MainActor.run {
                    self.allRooms = roomsResult
                    self.scores = scoresResult
                    self.applyFilterAndSort()
                    self.updateSubtitle()
                    self.refreshControl.endRefreshing()
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    self.isRefreshing = false
                    if let apiErr = error as? APIError, case .unauthorized = apiErr {
                        self.presentLogin()
                    } else if !silent {
                        AppLog.error("加载房间失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func applyFilterAndSort() {
        let filterHost = store.selectedHost
        var filtered = allRooms

        if filterHost != "all" {
            filtered = filtered.filter { $0.host == filterHost }
        }

        if store.roomSortMode == "status" {
            // 状态加权排序：录制中(0) > 备援接管(1) > 监听中在播(2) > 监听中(3) > 已停止(4)
            filtered.sort { r1, r2 in
                let w1 = statusWeight(r1)
                let w2 = statusWeight(r2)
                if w1 != w2 { return w1 < w2 }
                return r1.streamerName < r2.streamerName
            }
        }

        self.displayedRooms = filtered
        self.tableView.reloadData()
        self.updateSubtitle()
    }

    private func statusWeight(_ r: Room) -> Int {
        if r.recording { return 0 }
        if r.isFailoverActive { return 1 }
        if r.listening && r.isLive { return 2 }
        if r.listening { return 3 }
        return 4
    }

    private func updateSubtitle() {
        let rec = allRooms.filter { $0.recording }.count
        let lis = allRooms.filter { $0.listening }.count
        let total = allRooms.count
        let filterHost = store.selectedHost == "all" ? "全部" : store.selectedHost
        subtitleLabel.text = "在录 \(rec) · 监听 \(lis) · 共 \(total) (\(filterHost))"
    }

    // MARK: - 交互操作

    @objc private func openAddRoom() {
        Haptic.impact(.light)
        let addVC = AddRoomViewController()
        addVC.onRoomAdded = { [weak self] in
            self?.loadData()
        }
        present(addVC, animated: true)
    }

    @objc private func toggleSortMode() {
        Haptic.selection()
        let isStatus = store.roomSortMode == "status"
        store.roomSortMode = isStatus ? "created" : "status"

        let toast = UIAlertController(
            title: nil,
            message: isStatus ? "已切换为：添加时间排序" : "已切换为：状态优先排序 (在录置顶)",
            preferredStyle: .alert
        )
        present(toast, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            toast.dismiss(animated: true) { [weak self] in
                self?.applyFilterAndSort()
            }
        }
    }

    private func presentLogin() {
        let loginVC = LoginViewController()
        loginVC.onAuthenticated = { [weak self] in
            self?.loadData()
            loginVC.dismiss(animated: true)
        }
        present(loginVC, animated: true)
    }

    private func toggleListening(for room: Room) {
        Haptic.impact(.medium)
        Task {
            do {
                if room.listening {
                    try await client.stopRoom(id: room.id, host: room.host)
                } else {
                    try await client.startRoom(id: room.id, host: room.host)
                }
                await MainActor.run {
                    self.loadData(silent: true)
                }
            } catch {
                await MainActor.run {
                    let alert = UIAlertController(title: "操作失败", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func showModeEdit(for room: Room) {
        Haptic.selection()
        let sheet = UIAlertController(title: "修改监控模式", message: "主播：\(room.streamerName)", preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "设为永久监控", style: .default) { [weak self] _ in
            self?.submitModeChange(for: room, body: ["mode": "permanent"])
        })
        sheet.addAction(UIAlertAction(title: "临时监控 24 小时", style: .default) { [weak self] _ in
            let expiry = Int(Date().timeIntervalSince1970) + 86400
            self?.submitModeChange(for: room, body: ["expires_at": expiry])
        })
        sheet.addAction(UIAlertAction(title: "只录本场 (1 场)", style: .default) { [weak self] _ in
            self?.submitModeChange(for: room, body: ["sessions_left": 1])
        })
        sheet.addAction(UIAlertAction(title: "录 3 场", style: .default) { [weak self] _ in
            self?.submitModeChange(for: room, body: ["sessions_left": 3])
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(sheet, animated: true)
    }

    private func submitModeChange(for room: Room, body: [String: Any]) {
        Task {
            do {
                try await client.updateRoomMode(id: room.id, host: room.host, body: body)
                await MainActor.run {
                    Haptic.notification(.success)
                    self.loadData(silent: true)
                }
            } catch {
                await MainActor.run {
                    Haptic.notification(.error)
                    let alert = UIAlertController(title: "模式修改失败", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func confirmDelete(for room: Room) {
        let alert = UIAlertController(
            title: "删除房间",
            message: "确定从 \(room.host) 删除主播「\(room.streamerName)」吗？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.executeDelete(for: room)
        })
        present(alert, animated: true)
    }

    private func executeDelete(for room: Room) {
        Task {
            do {
                try await client.deleteRoom(id: room.id, host: room.host)
                await MainActor.run {
                    Haptic.notification(.success)
                    self.loadData(silent: true)
                }
            } catch {
                await MainActor.run {
                    Haptic.notification(.error)
                    let alert = UIAlertController(title: "删除失败", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    // MARK: - UITableViewDataSource & UITableViewDelegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedRooms.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: RoomCell.reuseIdentifier, for: indexPath) as? RoomCell else {
            return UITableViewCell()
        }
        let room = displayedRooms[indexPath.row]
        let score = scores[room.streamerName]
        cell.configure(with: room, score: score)
        cell.onToggleListening = { [weak self] in
            self?.toggleListening(for: room)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let room = displayedRooms[indexPath.row]
        showRoomDetailSheet(for: room)
    }

    private func showRoomDetailSheet(for room: Room) {
        Haptic.selection()
        let sheet = UIAlertController(
            title: "\(room.streamerName) (\(room.host))",
            message: "房间 ID: \(room.id)\n状态: \(room.statusText)\n模式: \(room.modeBadgeText)",
            preferredStyle: .actionSheet
        )

        sheet.addAction(UIAlertAction(title: room.listening ? "停止监听" : "开始监听", style: .default) { [weak self] _ in
            self?.toggleListening(for: room)
        })
        sheet.addAction(UIAlertAction(title: "修改监控模式", style: .default) { [weak self] _ in
            self?.showModeEdit(for: room)
        })
        sheet.addAction(UIAlertAction(title: "复制房间链接 / ID", style: .default) { _ in
            UIPasteboard.general.string = room.url ?? room.id
            Haptic.notification(.success)
        })
        if let score = scores[room.streamerName], let sId = score.streamerId, !sId.isEmpty {
            sheet.addAction(UIAlertAction(title: "在 dyzb 查看 AI 打分详情", style: .default) { [weak self] _ in
                let web = WebViewController(path: "/scoring/streamer/\(sId)", title: "AI 评分: \(room.streamerName)")
                self?.present(web, animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "删除房间", style: .destructive) { [weak self] _ in
            self?.confirmDelete(for: room)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(sheet, animated: true)
    }

    // MARK: - 滑动操作 (Swipe Actions)

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let room = displayedRooms[indexPath.row]
        let title = room.listening ? "停止" : "启动"
        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completionHandler in
            self?.toggleListening(for: room)
            completionHandler(true)
        }
        action.backgroundColor = room.listening ? Theme.warningYellow : Theme.listeningGreen
        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let room = displayedRooms[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completionHandler in
            self?.confirmDelete(for: room)
            completionHandler(true)
        }

        let modeAction = UIContextualAction(style: .normal, title: "改模式") { [weak self] _, _, completionHandler in
            self?.showModeEdit(for: room)
            completionHandler(true)
        }
        modeAction.backgroundColor = Theme.permanentBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, modeAction])
    }
}
