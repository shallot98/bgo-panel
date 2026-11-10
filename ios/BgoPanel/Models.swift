import Foundation
import UIKit

// MARK: - 房间模型 (Room)

struct ManagedInfo: Codable {
    let mode: String?
    let expiresAt: Double?
    let sessionsTotal: Int?
    let sessionsLeft: Int?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case expiresAt = "expires_at"
        case sessionsTotal = "sessions_total"
        case sessionsLeft = "sessions_left"
        case state
    }
}

struct FailoverInfo: Codable {
    let state: String?
    let agent: String?
    let startedAt: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case state
        case agent
        case startedAt = "started_at"
        case reason
    }
}

struct Room: Codable, Identifiable {
    let id: String
    let host: String
    let listening: Bool
    let recording: Bool
    let status: Int // 1 为正在直播，0 为下播
    let title: String?
    let streamerName: String
    let avatar: String?
    let url: String?
    let mode: String // "permanent" | "temp" | "session"
    let managed: ManagedInfo?
    let failover: FailoverInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case host
        case listening
        case recording
        case status
        case title
        case roomName = "room_name"
        case streamerName = "streamer_name"
        case hostName = "host_name"
        case name
        case nickName = "nick_name"
        case avatar
        case url
        case liveUrl = "live_url"
        case mode
        case managed
        case failover
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "boh"
        listening = try container.decodeIfPresent(Bool.self, forKey: .listening) ?? false
        recording = try container.decodeIfPresent(Bool.self, forKey: .recording) ?? false

        // 兼容 Int (1/0) 与 Bool (true/false) 与 String
        if let sInt = try? container.decodeIfPresent(Int.self, forKey: .status) {
            status = sInt
        } else if let sBool = try? container.decodeIfPresent(Bool.self, forKey: .status) {
            status = sBool ? 1 : 0
        } else if let sStr = try? container.decodeIfPresent(String.self, forKey: .status) {
            status = (sStr == "true" || sStr == "1") ? 1 : 0
        } else {
            status = 0
        }

        title = (try? container.decodeIfPresent(String.self, forKey: .title))
            ?? (try? container.decodeIfPresent(String.self, forKey: .roomName))

        if let sName = try? container.decodeIfPresent(String.self, forKey: .streamerName), !sName.isEmpty {
            streamerName = sName
        } else if let hName = try? container.decodeIfPresent(String.self, forKey: .hostName), !hName.isEmpty {
            streamerName = hName
        } else if let altName = try? container.decodeIfPresent(String.self, forKey: .name), !altName.isEmpty {
            streamerName = altName
        } else if let nName = try? container.decodeIfPresent(String.self, forKey: .nickName), !nName.isEmpty {
            streamerName = nName
        } else {
            streamerName = "未知主播"
        }

        avatar = try? container.decodeIfPresent(String.self, forKey: .avatar)
        url = (try? container.decodeIfPresent(String.self, forKey: .url))
            ?? (try? container.decodeIfPresent(String.self, forKey: .liveUrl))
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "permanent"
        managed = try container.decodeIfPresent(ManagedInfo.self, forKey: .managed)
        failover = try container.decodeIfPresent(FailoverInfo.self, forKey: .failover)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(host, forKey: .host)
        try container.encode(listening, forKey: .listening)
        try container.encode(recording, forKey: .recording)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(streamerName, forKey: .streamerName)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(managed, forKey: .managed)
        try container.encodeIfPresent(failover, forKey: .failover)
    }

    // MARK: - 业务辅助属性

    var isLive: Bool { status > 0 }

    var isFailoverActive: Bool {
        failover?.state == "active" || failover?.state == "releasing"
    }

    var statusColor: UIColor {
        if recording { return Theme.recordingRed }
        if isFailoverActive { return Theme.warningYellow }
        if listening { return Theme.listeningGreen }
        return Theme.textMuted
    }

    var statusText: String {
        if recording { return "🔴 录制中" }
        if isFailoverActive { return "⚠️ 备援接管中" }
        if listening { return isLive ? "🟢 直播中·监听中" : "🟢 监听中" }
        return "⚪ 已停止"
    }

    var modeBadgeText: String {
        switch mode {
        case "temp":
            if let exp = managed?.expiresAt {
                let leftSec = exp - Date().timeIntervalSince1970
                if leftSec > 0 {
                    let hours = Int(ceil(leftSec / 3600))
                    return "临时 剩 \(hours)h"
                }
                return "临时 已到期"
            }
            return "临时"
        case "session":
            let left = managed?.sessionsLeft ?? 1
            let total = managed?.sessionsTotal ?? 1
            if total == 1 { return "只录本场" }
            return "录 \(total) 场(剩 \(left))"
        default:
            return "永久"
        }
    }

    var modeBadgeColor: UIColor {
        switch mode {
        case "temp": return Theme.warningYellow
        case "session": return UIColor.systemPurple
        default: return Theme.permanentBlue
        }
    }
}

struct RoomsResponse: Codable {
    let rooms: [Room]
    let errors: [String: String]?
}

// MARK: - 总览与统计 (Overview)

struct OverviewCounts: Codable {
    let total: Int
    let listening: Int
    let living: Int
    let recording: Int
    let temp: Int
    let session: Int
}

struct OverviewResponse: Codable {
    let counts: OverviewCounts
}

// MARK: - 节点状态 (HostItem)

struct HostItem: Codable, Identifiable {
    var id: String { name }
    let name: String
    let local: Bool
    let ok: Bool
    let error: String?
    let total: Int
    let listening: Int
    let living: Int
    let recording: Int
    let managed: Int
}

// MARK: - dyzb AI 评分 (StreamerScore)

struct StreamerScore: Codable {
    let name: String?
    let streamerId: String?
    let total: Int?
    let scored: Int?
    let avgScore: Double?
    let maxScore: Double?
    let distribution: [String: Int]?
}

struct ScoresResponse: Codable {
    let enabled: Bool?
    let items: [String: StreamerScore]?
}

// MARK: - 通用操作响应

struct APIResponse: Codable {
    let ok: Bool?
    let success: Bool?
    let error: String?
    let message: String?
    let roomId: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case success
        case error
        case message
        case roomId = "room_id"
    }
}
