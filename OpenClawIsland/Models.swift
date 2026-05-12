import AppKit

enum WorkState: String, Codable, Equatable, CaseIterable {
    case idle
    case receiving
    case thinking
    case callingAPI
    case done
    case failed
    case playingMusic

    var emoji: String {
        switch self {
        case .idle: return "😐"
        case .receiving: return "👀"
        case .thinking: return "🤔"
        case .callingAPI: return "👀"
        case .done: return "😊"
        case .failed: return "☹️"
        case .playingMusic: return "🎵"
        }
    }

    var title: String {
        switch self {
        case .idle: return "待命"
        case .receiving: return "查找中"
        case .thinking: return "思考中"
        case .callingAPI: return "执行中"
        case .done: return "任务成功"
        case .failed: return "任务失败"
        case .playingMusic: return "播放中"
        }
    }

    var defaultDetail: String {
        switch self {
        case .idle: return "无任务执行"
        case .receiving: return "正在查找任务信息"
        case .thinking: return "OpenClaw 正在处理"
        case .callingAPI: return "正在调用工具"
        case .done: return "任务执行成功"
        case .failed: return "任务执行失败"
        case .playingMusic: return "媒体任务进行中"
        }
    }

    var statusColor: NSColor {
        switch self {
        case .idle: return .systemGray
        case .receiving: return .systemBlue
        case .thinking: return .systemPurple
        case .callingAPI: return .systemOrange
        case .done: return .systemGreen
        case .failed: return .systemRed
        case .playingMusic: return .systemPink
        }
    }

    var isTransient: Bool {
        self == .done || self == .failed
    }
}

struct Agent: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var avatar: String
    var state: WorkState
    var detail: String
    var updatedAt: Date
    var sequence: Int

    init(
        id: String,
        name: String,
        avatar: String,
        state: WorkState = .idle,
        detail: String = WorkState.idle.defaultDetail,
        updatedAt: Date = Date.distantPast,
        sequence: Int = 0
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
        self.sequence = sequence
    }
}
