import AppKit
import Foundation

final class IslandViewModel {
    var agents: [Agent] {
        didSet { notify() }
    }
    var activeAgentId: String {
        didSet { notify() }
    }
    var isExpanded: Bool = false {
        didSet { notify() }
    }
    var isPointerInside: Bool = false {
        didSet { notify() }
    }
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var processedEvents = Set<String>()
    private var nextSequence = 1
    private var urlHoldUntil: [String: Date] = [:]
    private var collapseToken = 0
    private var manualSelectionUntil: Date?
    private var telegramUpdateOffsets: [String: Int64] = [:]

    init() {
        let loadedAgents = AgentCatalog.load()
        self.agents = loadedAgents
        self.activeAgentId = loadedAgents.first?.id ?? "main"
        startMonitoring()
        notify()
    }

    deinit {
        timer?.invalidate()
    }

    var activeAgent: Agent {
        let selected = agents.first(where: { $0.id == activeAgentId }) ?? agents[0]
        if let manualSelectionUntil, manualSelectionUntil > Date() {
            return selected
        }
        guard let newestVisible = visibleAgents.max(by: { $0.sequence < $1.sequence }) else {
            return selected
        }
        if selected.state == .idle || newestVisible.sequence > selected.sequence {
            return newestVisible
        }
        return selected
    }

    var visibleAgents: [Agent] {
        agents.filter { $0.state != .idle }
    }

    var shouldShowIsland: Bool {
        !visibleAgents.isEmpty
    }

    func setAgent(id: String) {
        guard agents.contains(where: { $0.id == id }) else { return }
        manualSelectionUntil = Date().addingTimeInterval(8.0)
        activeAgentId = id
    }

    func selectNextAgent(direction: Int) {
        guard let index = agents.firstIndex(where: { $0.id == activeAgentId }), !agents.isEmpty else {
            if let first = agents.first { setAgent(id: first.id) }
            return
        }
        let nextIndex = (index + direction + agents.count) % agents.count
        setAgent(id: agents[nextIndex].id)
    }

    func toggleExpandedByUser() {
        isExpanded.toggle()
        if isExpanded {
            scheduleAutoCollapse(after: 5.5)
        }
    }

    func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        if inside {
            collapseToken += 1
            isExpanded = true
        } else {
            scheduleAutoCollapse(after: 0.35)
        }
    }

    func updateState(
        agentId: String? = nil,
        name: String? = nil,
        avatar: String? = nil,
        state: WorkState,
        detail: String? = nil,
        date: Date = Date(),
        autoSelect: Bool = true
    ) {
        let id = agentId?.isEmpty == false ? agentId! : activeAgentId
        ensureAgent(id: id, name: name, avatar: avatar)

        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        if agents[index].updatedAt > date { return }

        var agent = agents[index]
        if let name, !name.isEmpty { agent.name = name }
        if let avatar, !avatar.isEmpty { agent.avatar = avatar }
        agent.state = state
        agent.detail = cleaned(detail ?? state.defaultDetail)
        agent.updatedAt = date
        agent.sequence = nextSequence
        nextSequence += 1

        agents[index] = agent
        if autoSelect, state != .idle {
            manualSelectionUntil = nil
            activeAgentId = id
        }

        if state != .idle {
            expandTemporarily()
        }

        if state.isTransient {
            scheduleIdleReset(agentId: id, sequence: agent.sequence)
        } else if state == .receiving {
            scheduleThinkingPromotion(agentId: id, sequence: agent.sequence)
        } else if state == .thinking || state == .callingAPI {
            scheduleLongRunningNotice(agentId: id, sequence: agent.sequence)
        }
    }

    func updateState(fromURL url: URL) {
        guard url.host == "update" || url.host == "state" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let items = components.queryItems ?? []
        let stateValue = items.value("state") ?? "idle"
        let state = WorkState(rawValue: stateValue) ?? .idle
        let agentId = items.value("agent") ?? items.value("agentId") ?? items.value("id")
        let detail = items.value("msg") ?? items.value("message") ?? items.value("detail")
        let name = items.value("name")
        let avatar = items.value("avatar")

        updateState(agentId: agentId, name: name, avatar: avatar, state: state, detail: detail)
        let id = agentId?.isEmpty == false ? agentId! : activeAgentId
        urlHoldUntil[id] = Date().addingTimeInterval(2.0)
    }

    func simulateWeatherFlow() {
        let id = activeAgentId
        updateState(agentId: id, state: .receiving, detail: "收到新的任务")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.updateState(agentId: id, state: .thinking, detail: "OpenClaw 在处理")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.updateState(agentId: id, state: .callingAPI, detail: "正在调用工具")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.updateState(agentId: id, state: .done, detail: "任务执行成功")
        }
    }

    private func startMonitoring() {
        restoreRecentLogState()
        restoreRecentTelegramUpdates()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshAgentsIfNeeded()
            self?.ingestTelegramUpdates()
            self?.ingestOpenClawLogs()
        }
    }

    private func restoreRecentLogState() {
        let files = OpenClawLogReader.latestSessionFiles(for: agents.map(\.id))
        for file in files {
            let events = OpenClawLogReader.readRecentEvents(from: file, knownEvents: Set<String>())
            for event in events {
                processedEvents.insert(event.key)
            }
            if let latest = events.sorted(by: { $0.date < $1.date }).last, shouldRestore(latest) {
                apply(latest)
            }
        }
    }

    private func shouldRestore(_ event: OpenClawEvent) -> Bool {
        let age = Date().timeIntervalSince(event.date)
        switch event.kind {
        case .done, .failed:
            return age <= 10
        case .userMessage, .assistantThinking, .toolCall, .toolResult:
            return age <= 60 * 60
        }
    }

    private func ingestOpenClawLogs() {
        refreshAgentsIfNeeded()
        let files = OpenClawLogReader.latestSessionFiles(for: agents.map(\.id))
        for file in files {
            let events = OpenClawLogReader.readRecentEvents(from: file, knownEvents: processedEvents)
            for event in events {
                processedEvents.insert(event.key)
                apply(event)
            }
        }

        if processedEvents.count > 800 {
            processedEvents = Set(processedEvents.prefix(400))
        }
    }

    private func restoreRecentTelegramUpdates() {
        for update in TelegramUpdateReader.currentUpdates() {
            telegramUpdateOffsets[update.accountId] = update.lastUpdateId
            guard update.modifiedAt.timeIntervalSinceNow > -120 else { continue }
            updateState(
                agentId: update.agentId,
                state: .receiving,
                detail: "收到 Telegram 消息",
                date: update.modifiedAt
            )
        }
    }

    private func ingestTelegramUpdates() {
        for update in TelegramUpdateReader.currentUpdates() {
            let previous = telegramUpdateOffsets[update.accountId]
            telegramUpdateOffsets[update.accountId] = update.lastUpdateId
            if let previous {
                guard update.lastUpdateId > previous else { continue }
            } else {
                guard update.modifiedAt.timeIntervalSinceNow > -120 else { continue }
            }
            updateState(
                agentId: update.agentId,
                state: .receiving,
                detail: "收到 Telegram 消息",
                date: update.modifiedAt
            )
        }
    }

    private func refreshAgentsIfNeeded() {
        for discovered in AgentCatalog.load() {
            if let index = agents.firstIndex(where: { $0.id == discovered.id }) {
                var agent = agents[index]
                agent.name = discovered.name
                agent.avatar = discovered.avatar
                agents[index] = agent
            } else {
                agents.append(discovered)
            }
        }
    }

    private func apply(_ event: OpenClawEvent) {
        if let holdUntil = urlHoldUntil[event.agentId] {
            if holdUntil > Date() {
                return
            }
            urlHoldUntil[event.agentId] = nil
        }

        switch event.kind {
        case .userMessage:
            updateState(agentId: event.agentId, state: .receiving, detail: event.detail, date: event.date)
        case .assistantThinking:
            updateState(agentId: event.agentId, state: .thinking, detail: event.detail, date: event.date)
        case .toolCall:
            updateState(agentId: event.agentId, state: .callingAPI, detail: event.detail, date: event.date)
        case .toolResult:
            updateState(agentId: event.agentId, state: .thinking, detail: event.detail, date: event.date)
        case .done:
            updateState(agentId: event.agentId, state: .done, detail: event.detail, date: event.date)
        case .failed:
            updateState(agentId: event.agentId, state: .failed, detail: event.detail, date: event.date)
        }
    }

    private func ensureAgent(id: String, name: String?, avatar: String?) {
        guard !agents.contains(where: { $0.id == id }) else { return }
        agents.append(Agent(id: id, name: name ?? id, avatar: avatar ?? AgentCatalog.avatar(for: id, name: name ?? id)))
    }

    private func scheduleIdleReset(agentId: String, sequence: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self else { return }
            guard let index = self.agents.firstIndex(where: { $0.id == agentId }) else { return }
            guard self.agents[index].sequence == sequence else { return }
            var agent = self.agents[index]
            agent.state = .idle
            agent.detail = WorkState.idle.defaultDetail
            agent.updatedAt = Date()
            self.agents[index] = agent
            if self.activeAgentId == agentId, let next = self.visibleAgents.max(by: { $0.sequence < $1.sequence }) {
                self.activeAgentId = next.id
            }
            if self.visibleAgents.isEmpty {
                self.isExpanded = false
            }
        }
    }

    private func scheduleThinkingPromotion(agentId: String, sequence: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self else { return }
            guard let index = self.agents.firstIndex(where: { $0.id == agentId }) else { return }
            guard self.agents[index].sequence == sequence else { return }
            guard self.agents[index].state == .receiving else { return }

            var agent = self.agents[index]
            agent.state = .thinking
            agent.detail = "已收到任务，正在等待 OpenClaw 处理"
            agent.updatedAt = Date()
            self.agents[index] = agent
            self.scheduleLongRunningNotice(agentId: agentId, sequence: sequence)
        }
    }

    private func scheduleLongRunningNotice(agentId: String, sequence: Int) {
        let notices: [(TimeInterval, String)] = [
            (60, "仍在处理，任务耗时较长"),
            (5 * 60, "仍在思考，可能正在等待模型或工具返回"),
            (15 * 60, "持续处理中，建议点开聊天窗口确认是否卡住")
        ]

        for notice in notices {
            DispatchQueue.main.asyncAfter(deadline: .now() + notice.0) { [weak self] in
                guard let self else { return }
                guard let index = self.agents.firstIndex(where: { $0.id == agentId }) else { return }
                guard self.agents[index].sequence == sequence else { return }
                guard self.agents[index].state == .thinking || self.agents[index].state == .callingAPI else { return }

                var agent = self.agents[index]
                agent.detail = notice.1
                agent.updatedAt = Date()
                self.agents[index] = agent
            }
        }
    }

    private func expandTemporarily() {
        isExpanded = true
        scheduleAutoCollapse(after: 4.0)
    }

    private func scheduleAutoCollapse(after seconds: TimeInterval) {
        collapseToken += 1
        let token = collapseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.collapseToken == token else { return }
            guard !self.isPointerInside else { return }
            self.isExpanded = false
        }
    }

    private func notify() {
        writeSnapshot()
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    private func writeSnapshot() {
        let snapshot: [String: Any] = [
            "activeAgentId": activeAgentId,
            "isExpanded": isExpanded,
            "isPointerInside": isPointerInside,
            "isVisible": shouldShowIsland,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "agents": agents.map { agent in
                [
                    "id": agent.id,
                    "name": agent.name,
                    "avatar": agent.avatar,
                    "state": agent.state.rawValue,
                    "title": agent.state.title,
                    "emoji": agent.state.emoji,
                    "detail": agent.detail,
                    "updatedAt": ISO8601DateFormatter().string(from: agent.updatedAt),
                    "sequence": agent.sequence
                ] as [String: Any]
            }
        ]

        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/openclawisland-state.json"), options: [.atomic])
    }

    private func cleaned(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == URLQueryItem {
    func value(_ name: String) -> String? {
        first(where: { $0.name == name })?.value?.removingPercentEncoding
    }
}

private enum OpenClawEventKind {
    case userMessage
    case assistantThinking
    case toolCall
    case toolResult
    case done
    case failed
}

private struct OpenClawEvent {
    var key: String
    var agentId: String
    var date: Date
    var kind: OpenClawEventKind
    var detail: String
}

private enum AgentCatalog {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/openclaw.json")
    }

    static func load() -> [Agent] {
        var discovered: [String: Agent] = [:]
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let configuredAgents = root.value(at: ["agents", "list"]) as? [[String: Any]] {
                for item in configuredAgents {
                    guard let id = item["id"] as? String, !id.isEmpty else { continue }
                    let name = item["name"] as? String ?? id
                    let avatar = item["avatar"] as? String ?? avatar(for: id, name: name)
                    discovered[id] = Agent(id: id, name: name, avatar: avatar)
                }
            }

            if let bindings = root["bindings"] as? [[String: Any]] {
                for binding in bindings {
                    guard let id = binding["agentId"] as? String, !id.isEmpty, discovered[id] == nil else { continue }
                    discovered[id] = Agent(id: id, name: id, avatar: avatar(for: id, name: id))
                }
            }
        }

        let agentsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/agents")
        if let urls = try? FileManager.default.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let id = url.lastPathComponent
                guard !id.isEmpty, discovered[id] == nil else { continue }
                discovered[id] = Agent(id: id, name: id, avatar: avatar(for: id, name: id))
            }
        }

        if discovered.isEmpty {
            return [Agent(id: "default", name: "Default Agent", avatar: "🤖")]
        }

        return discovered.values.sorted { lhs, rhs in
            if lhs.id == "main" { return true }
            if rhs.id == "main" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func avatar(for id: String, name: String) -> String {
        let choices = ["🤖", "🧠", "🔎", "🛠️", "📡", "💬", "⚙️", "✨"]
        let value = abs(id.hashValue ^ name.hashValue)
        return choices[value % choices.count]
    }
}

private struct TelegramUpdate {
    var accountId: String
    var agentId: String
    var lastUpdateId: Int64
    var modifiedAt: Date
}

private enum TelegramUpdateReader {
    static func currentUpdates() -> [TelegramUpdate] {
        let routes = telegramRoutes()
        guard !routes.isEmpty else { return [] }

        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/telegram")
        return routes.compactMap { accountId, agentId in
            let url = directory.appendingPathComponent("update-offset-\(accountId).json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let updateId = numberValue(root["lastUpdateId"]) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return TelegramUpdate(
                accountId: accountId,
                agentId: agentId,
                lastUpdateId: updateId,
                modifiedAt: values?.contentModificationDate ?? Date()
            )
        }
    }

    private static func telegramRoutes() -> [String: String] {
        guard let data = try? Data(contentsOf: AgentCatalog.configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bindings = root["bindings"] as? [[String: Any]] else {
            return [:]
        }

        var routes: [String: String] = [:]
        for binding in bindings {
            guard let agentId = binding["agentId"] as? String, !agentId.isEmpty else { continue }
            guard let match = binding["match"] as? [String: Any] else { continue }
            guard match["channel"] as? String == "telegram" else { continue }
            guard let accountId = match["accountId"] as? String, !accountId.isEmpty else { continue }
            routes[accountId] = agentId
        }
        return routes
    }

    private static func numberValue(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }
}

private enum OpenClawLogReader {
    static func latestSessionFiles(for agentIds: [String]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".openclaw/agents")
        let now = Date()

        return agentIds.compactMap { agentId in
            let sessions = base.appendingPathComponent(agentId).appendingPathComponent("sessions")
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: sessions,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }

            return urls
                .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.contains("trajectory") }
                .compactMap { url -> (URL, Date)? in
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let date = values?.contentModificationDate else { return nil }
                    guard now.timeIntervalSince(date) < 60 * 60 * 8 else { return nil }
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
                .first?
                .0
        }
    }

    static func readRecentEvents(from url: URL, knownEvents: Set<String>) -> [OpenClawEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let slice = data.suffix(128 * 1024)
        guard let text = String(data: slice, encoding: .utf8) else { return [] }

        let agentId = agentIdFromPath(url) ?? "main"
        return text
            .split(separator: "\n")
            .compactMap { parse(line: String($0), agentId: agentId, file: url) }
            .filter { !knownEvents.contains($0.key) }
            .sorted { $0.date < $1.date }
    }

    private static func parse(line: String, agentId: String, file: URL) -> OpenClawEvent? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = (root["id"] as? String) ?? String(line.hashValue)
        let key = "\(file.path):\(id)"
        let date = parseDate(root["timestamp"] as? String) ?? Date()

        if root["type"] as? String == "session" {
            return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .assistantThinking, detail: "OpenClaw 会话启动")
        }

        if root["customType"] as? String == "openclaw:prompt-error" {
            let error = root.value(at: ["data", "error"]) as? String
            return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .failed, detail: error ?? "模型调用被中断")
        }

        guard let message = root["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return nil
        }

        if role == "user" {
            let text = firstText(in: message)
            if isHeartbeatPoll(text) {
                return nil
            }
            return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .userMessage, detail: text ?? "收到新的任务")
        }

        if role == "toolResult" {
            let toolName = message["toolName"] as? String ?? "工具"
            let status = root.value(at: ["message", "details", "status"]) as? String
            let suffix = status == "running" ? "仍在运行" : "已返回，整理结果"
            return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .toolResult, detail: "\(toolName) \(suffix)")
        }

        if role == "assistant" {
            if let callName = firstToolCallName(in: message) {
                return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .toolCall, detail: "正在调用 \(callName)")
            }
            if (message["stopReason"] as? String) == "error" {
                return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .failed, detail: message["errorMessage"] as? String ?? "助手执行失败")
            }
            if let text = firstText(in: message), !text.isEmpty {
                return OpenClawEvent(key: key, agentId: agentId, date: date, kind: .done, detail: text)
            }
        }

        return nil
    }

    private static func agentIdFromPath(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "agents"), parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func firstText(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        for item in content {
            if item["type"] as? String == "text", let text = item["text"] as? String {
                return shortened(text)
            }
        }
        return nil
    }

    private static func firstToolCallName(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        for item in content {
            if item["type"] as? String == "toolCall", let name = item["name"] as? String {
                return name
            }
        }
        return nil
    }

    private static func shortened(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 90 { return cleaned }
        return String(cleaned.prefix(90)) + "..."
    }

    private static func isHeartbeatPoll(_ text: String?) -> Bool {
        let normalized = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "[openclaw heartbeat poll]"
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        var current: Any? = self
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }
}
