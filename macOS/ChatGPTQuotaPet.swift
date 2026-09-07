import AppKit
import Combine
import Foundation
import SwiftUI

struct QuotaWindow {
    let remaining: Double?
    let used: Double?
    let resetAt: TimeInterval?
    let windowMinutes: Double?
}

struct QuotaSnapshot {
    let planType: String?
    let primary: QuotaWindow
    let secondary: QuotaWindow
    let sampledAt: Date
    let sourceName: String
}

enum QuotaParser {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    static func value(_ dictionary: [String: Any]?, names: [String]) -> Any? {
        guard let dictionary else { return nil }
        for name in names {
            if let value = dictionary[name], !(value is NSNull) {
                return value
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func snapshot(from limitsValue: Any?, sampledAt: Date, sourceName: String) -> QuotaSnapshot? {
        guard let limits = dictionary(limitsValue) else { return nil }
        let primary = window(from: value(limits, names: ["primary"]))
        let secondary = window(from: value(limits, names: ["secondary"]))
        guard primary.used != nil || secondary.used != nil else { return nil }

        let plan = value(limits, names: ["plan_type", "planType"]) as? String
        return QuotaSnapshot(
            planType: plan,
            primary: primary,
            secondary: secondary,
            sampledAt: sampledAt,
            sourceName: sourceName
        )
    }

    private static func window(from rawValue: Any?) -> QuotaWindow {
        let object = dictionary(rawValue)
        let used = number(QuotaParser.value(object, names: ["used_percent", "usedPercent"]))
        let remaining = used.map { min(100, max(0, 100 - $0)) }
        let resetAt = number(QuotaParser.value(object, names: ["resets_at", "resetsAt"]))
        let windowMinutes = number(QuotaParser.value(object, names: ["window_minutes", "windowDurationMins", "window_duration_mins"]))
        return QuotaWindow(remaining: remaining, used: used, resetAt: resetAt, windowMinutes: windowMinutes)
    }
}

enum SnapshotLoader {
    static func load(root: URL) -> QuotaSnapshot? {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let urls = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { return nil }
            return url
        }
        .sorted { modificationDate($0) > modificationDate($1) }
        .prefix(24)

        for url in urls {
            for line in readTailLines(url: url) where line.contains("\"rate_limits\"") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] ?? payload["rateLimits"] else { continue }

                let sampledAt = parseDate(event["timestamp"]) ?? modificationDate(url)
                if let snapshot = QuotaParser.snapshot(from: limits, sampledAt: sampledAt, sourceName: url.lastPathComponent) {
                    return snapshot
                }
            }
        }
        return nil
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
    }

    private static func readTailLines(url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let tailSize: UInt64 = 512 * 1024
        let start = end > tailSize ? end - tailSize : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).reversed().map(String.init)
    }
}

final class CodexAppServerClient {
    var onSnapshot: ((QuotaSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.local.chatgpt.quotapet.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var initializeID: Int?
    private var pendingReadID: Int?
    private var pendingSince: Date?
    private var ready = false
    private var lastError = ""

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if let pendingSince = self.pendingSince, Date().timeIntervalSince(pendingSince) > 20 {
                self.closeOnQueue()
            }
            if self.process?.isRunning != true {
                self.startOnQueue()
            } else if self.ready && self.pendingReadID == nil {
                self.requestReadOnQueue()
            }
        }
    }

    func stop() {
        queue.sync { closeOnQueue() }
    }

    var currentError: String {
        queue.sync { lastError }
    }

    private func executableURL() -> URL? {
        let fileManager = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["CODEX_BIN"], fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func startOnQueue() {
        closeOnQueue()
        guard let executable = executableURL() else {
            emitError("未找到 codex，请确认 ChatGPT/Codex 已安装")
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading
        self.buffer.removeAll(keepingCapacity: true)
        self.ready = false
        self.initializeID = nil
        self.pendingReadID = nil
        self.pendingSince = nil

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            self?.queue.async { [weak self] in
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.process?.isRunning != true else { return }
                self.emitErrorIfNeeded()
            }
        }

        do {
            try process.run()
        } catch {
            emitError("无法启动本地额度接口：\(error.localizedDescription)")
            closeOnQueue()
            return
        }

        nextID = 1
        initializeID = nextID
        sendOnQueue([
            "jsonrpc": "2.0",
            "id": nextID,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "chatgpt-quota-pet-mac", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ])
    }

    private func sendOnQueue(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        try? input.write(contentsOf: Data(line.utf8))
    }

    private func requestReadOnQueue() {
        guard ready, pendingReadID == nil else { return }
        nextID += 1
        pendingReadID = nextID
        pendingSince = Date()
        sendOnQueue(["jsonrpc": "2.0", "id": nextID, "method": "account/rateLimits/read", "params": NSNull()])
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String, method == "account/rateLimits/updated" {
            let params = message["params"] as? [String: Any]
            let limits = params?["rateLimits"] ?? params?["rate_limits"]
            if let snapshot = QuotaParser.snapshot(from: limits, sampledAt: Date(), sourceName: "app-server") {
                onSnapshot?(snapshot)
                lastError = ""
            }
            return
        }

        guard let messageID = QuotaParser.number(message["id"]).map({ Int($0) }) else { return }
        if messageID == initializeID {
            initializeID = nil
            if let error = message["error"] as? [String: Any], let text = error["message"] as? String {
                emitError(text)
                closeOnQueue()
                return
            }
            ready = true
            sendOnQueue(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: Any]])
            requestReadOnQueue()
            return
        }

        guard messageID == pendingReadID else { return }
        pendingReadID = nil
        pendingSince = nil
        if let result = message["result"] as? [String: Any],
           let limits = result["rateLimits"] ?? result["rate_limits"],
           let snapshot = QuotaParser.snapshot(from: limits, sampledAt: Date(), sourceName: "app-server") {
            onSnapshot?(snapshot)
            lastError = ""
        } else if let error = message["error"] as? [String: Any], let text = error["message"] as? String {
            emitError(text)
        } else {
            emitError("额度接口没有返回数据")
        }
    }

    private func emitError(_ message: String) {
        lastError = message
        onError?(message)
    }

    private func emitErrorIfNeeded() {
        if lastError.isEmpty {
            emitError("本地额度接口已退出")
        }
    }

    private func closeOnQueue() {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        input?.closeFile()
        output?.closeFile()
        errorOutput?.closeFile()
        process?.terminationHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        ready = false
        initializeID = nil
        pendingReadID = nil
        pendingSince = nil
    }
}

enum QuotaFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func caption(minutes: Double?, fallback: String) -> String {
        guard let minutes else { return fallback }
        let rounded = Int(minutes.rounded())
        guard rounded > 0 else { return fallback }
        if rounded % 1440 == 0 { return "\(rounded / 1440) 天窗口剩余" }
        if rounded % 60 == 0 { return "\(rounded / 60) 小时窗口剩余" }
        return "\(rounded) 分钟窗口剩余"
    }

    static func reset(_ timestamp: TimeInterval?) -> String {
        guard let timestamp else { return "重置时间未知" }
        let seconds = timestamp - Date().timeIntervalSince1970
        if seconds <= 0 { return "窗口已到点，等待刷新" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "约 \(minutes) 分钟后重置" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let rest = minutes % 60
        if days > 0 { return "约 \(days) 天 \(hours) 小时后重置" }
        return "约 \(hours) 小时 \(rest) 分钟后重置"
    }

    static func consumptionRate(
        window: QuotaWindow,
        fallbackWindowMinutes: Double,
        displayPeriodMinutes: Double,
        unit: String
    ) -> String {
        guard let resetAt = window.resetAt, let usedValue = window.used else { return "等待数据" }

        let totalMinutes = max(1, window.windowMinutes ?? fallbackWindowMinutes)
        let remainingMinutes = min(
            totalMinutes,
            max(0, (resetAt - Date().timeIntervalSince1970) / 60)
        )
        let elapsedMinutes = totalMinutes - remainingMinutes
        guard elapsedMinutes >= 1 else { return "等待数据" }

        let used = min(100, max(0, usedValue))
        let rate = used / elapsedMinutes * displayPeriodMinutes
        guard rate.isFinite else { return "等待数据" }
        return String(format: "%.1f%%/%@", rate, unit)
    }

    static func shortError(_ error: String) -> String {
        if error.isEmpty { return "" }
        if error.range(of: "codex", options: [.caseInsensitive]) != nil &&
            (error.contains("not found") || error.contains("找不到") || error.contains("executable")) {
            return "未找到 codex"
        }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(22))
    }
}

@MainActor
final class QuotaModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var fallbackSnapshot: QuotaSnapshot?
    @Published private(set) var connectionError = ""
    @Published private(set) var footer = "正在连接本地额度接口…"

    private let client = CodexAppServerClient()
    private let codexHome: URL
    private let refreshSeconds: TimeInterval
    private var timer: Timer?

    init(refreshSeconds: TimeInterval = 1) {
        self.refreshSeconds = refreshSeconds
        codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
                self?.connectionError = ""
                self?.updateFooter(snapshot)
            }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in self?.connectionError = message }
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        fallbackSnapshot = SnapshotLoader.load(root: codexHome)
        client.refresh()
        let display = snapshot ?? fallbackSnapshot
        if let display { updateFooter(display) } else { footer = "正在连接本地额度接口…" }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        client.stop()
    }

    private func updateFooter(_ value: QuotaSnapshot) {
        let ageMinutes = max(0, Date().timeIntervalSince(value.sampledAt) / 60)
        let formatter = DateFormatter()
        formatter.dateFormat = ageMinutes >= 10 ? "MM-dd HH:mm" : "HH:mm"
        let source = value.sourceName == "app-server" ? "实时" : "快照"
        let stale = ageMinutes >= 10 ? " · 可能过期" : ""
        let shortError = QuotaFormatter.shortError(connectionError)
        let error = value.sourceName == "app-server" || shortError.isEmpty ? "" : " · \(shortError)"
        footer = "\(source) \(formatter.string(from: value.sampledAt))\(stale)\(error)"
    }
}

private struct LiquidGlassBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.38)

            Circle()
                .fill(Color(red: 0.42, green: 0.70, blue: 1.0).opacity(0.29))
                .frame(width: 240, height: 240)
                .blur(radius: 34)
                .offset(x: -145, y: -120)

            Circle()
                .fill(Color(red: 0.65, green: 0.52, blue: 1.0).opacity(0.22))
                .frame(width: 220, height: 220)
                .blur(radius: 36)
                .offset(x: 158, y: 122)

            Rectangle()
                .fill(.ultraThinMaterial)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.025),
                            Color.blue.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipped()
        // NSPopover owns the outer contour, border, and shadow. Fill its
        // content bounds so a second rounded mask cannot expose its backing.
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(.ultraThinMaterial))
        .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 0.8))
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

private struct QuotaRing: View {
    let label: String
    let progress: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 5)
            Circle()
                // Advance the consumed edge clockwise from 12 o’clock.
                .trim(from: 1 - progress, to: 1)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.45), tint, tint.opacity(0.72)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.36), radius: 4)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.72))
        }
        .frame(width: 52, height: 52)
        .animation(.easeOut(duration: 0.35), value: progress)
    }
}

private struct QuotaCard: View {
    let title: String
    let badge: String
    let window: QuotaWindow
    let fallbackWindowMinutes: Double
    let ratePeriodMinutes: Double
    let rateUnit: String

    private var tint: Color {
        guard let remaining = window.remaining else { return Color.gray.opacity(0.55) }
        if remaining <= 10 { return Color(red: 0.94, green: 0.29, blue: 0.30) }
        if remaining <= 30 { return Color(red: 0.96, green: 0.60, blue: 0.06) }
        return Color(red: 0.08, green: 0.71, blue: 0.54)
    }

    private var progress: CGFloat {
        CGFloat(min(100, max(0, window.remaining ?? 0)) / 100)
    }

    private var consumptionRate: String {
        QuotaFormatter.consumptionRate(
            window: window,
            fallbackWindowMinutes: fallbackWindowMinutes,
            displayPeriodMinutes: ratePeriodMinutes,
            unit: rateUnit
        )
    }

    var body: some View {
        HStack(spacing: 13) {
            QuotaRing(label: badge, progress: progress, tint: tint)

            VStack(alignment: .leading, spacing: 5) {
                Text(QuotaFormatter.caption(minutes: window.windowMinutes, fallback: title))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(QuotaFormatter.reset(window.resetAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(QuotaFormatter.percent(window.remaining))
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(consumptionRate)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("按当前窗口已用额度与已过时长折算")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.54), Color.white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 5)
    }
}

struct QuotaView: View {
    @ObservedObject var model: QuotaModel
    let refresh: () -> Void
    let dismiss: () -> Void

    private let placeholder = QuotaWindow(remaining: nil, used: nil, resetAt: nil, windowMinutes: nil)

    private var currentSnapshot: QuotaSnapshot? {
        model.snapshot ?? model.fallbackSnapshot
    }

    private var planTitle: String {
        let plan = currentSnapshot?.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plan, !plan.isEmpty {
            return "\(plan.capitalized) 额度"
        }
        return "订阅额度"
    }

    private var statusTint: Color {
        currentSnapshot?.sourceName == "app-server"
            ? Color(red: 0.08, green: 0.71, blue: 0.54)
            : Color(red: 0.96, green: 0.60, blue: 0.06)
    }

    private var statusBadge: String {
        guard let currentSnapshot else { return "WAIT" }
        return currentSnapshot.sourceName == "app-server" ? "LIVE" : "SNAPSHOT"
    }

    var body: some View {
        ZStack {
            LiquidGlassBackground()

            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.25, green: 0.57, blue: 1.0),
                                        Color(red: 0.43, green: 0.32, blue: 0.92)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "gauge.medium")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 38, height: 38)
                    .shadow(color: Color.blue.opacity(0.28), radius: 9, y: 4)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(planTitle)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 7) {
                        GlassIconButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新额度", action: refresh)
                        GlassIconButton(systemName: "xmark", accessibilityLabel: "关闭详情", action: dismiss)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.top, 16)
                .padding(.bottom, 13)

                VStack(spacing: 10) {
                    QuotaCard(
                        title: "5 小时窗口剩余",
                        badge: "5h",
                        window: currentSnapshot?.primary ?? placeholder,
                        fallbackWindowMinutes: 5 * 60,
                        ratePeriodMinutes: 30,
                        rateUnit: "30min"
                    )
                    QuotaCard(
                        title: "7 天窗口剩余",
                        badge: "7d",
                        window: currentSnapshot?.secondary ?? placeholder,
                        fallbackWindowMinutes: 7 * 24 * 60,
                        ratePeriodMinutes: 24 * 60,
                        rateUnit: "天"
                    )
                }
                .padding(.horizontal, 14)

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusTint.opacity(0.55), radius: 4)
                    Text(model.footer)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    Text(statusBadge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(statusTint)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.7))
                .padding(.horizontal, 17)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 386, height: 292)
    }
}

final class QuotaStatusView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private let iconLeading: CGFloat = 2
    private let labelLeading: CGFloat = 23
    private let labelTrailing: CGFloat = 6
    private let labelSafetyPadding: CGFloat = 8
    private let minimumWidth: CGFloat = 84
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "5h —")
    private let secondaryLabel = NSTextField(labelWithString: "7d —")
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Codex 剩余额度")

        iconView.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Codex 额度")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        for label in [primaryLabel, secondaryLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.backgroundColor = .clear
            label.isBordered = false
            label.isEditable = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: iconLeading, y: 3, width: 18, height: 18)
        let labelWidth = max(20, bounds.width - labelLeading - labelTrailing)
        primaryLabel.frame = NSRect(x: labelLeading, y: 1, width: labelWidth, height: 10)
        secondaryLabel.frame = NSRect(x: labelLeading, y: 11, width: labelWidth, height: 10)
    }

    var preferredWidth: CGFloat {
        let font = primaryLabel.font ?? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let labelWidths = [
            primaryLabel.stringValue,
            secondaryLabel.stringValue,
            "5h 100%",
            "7d 100%"
        ].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        return max(
            minimumWidth,
            ceil(labelLeading + (labelWidths.max() ?? 0) + labelTrailing + labelSafetyPadding)
        )
    }

    func update(primary: Double?, secondary: Double?, sourceName: String?) {
        primaryLabel.stringValue = "5h \(QuotaFormatter.percent(primary))"
        secondaryLabel.stringValue = "7d \(QuotaFormatter.percent(secondary))"
        let source = sourceName == "app-server" ? "实时" : (sourceName == nil ? "等待数据" : "快照")
        toolTip = "Codex 额度 · \(source)"
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            NSColor.selectedMenuItemColor.withAlphaComponent(0.25).setFill()
            dirtyRect.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        onLeftClick?()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = QuotaModel()
    private var popover: NSPopover!
    private var statusItem: NSStatusItem!
    private var statusView: QuotaStatusView!
    private let statusMenu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPopover()
        buildStatusItem()
        model.$snapshot
            .combineLatest(model.$fallbackSnapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.start()
        updateStatusItem()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
        installPopoverDismissMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePopoverDismissMonitors()
        model.stop()
    }

    private func buildPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 386, height: 292)

        let hostingController = NSHostingController(rootView: QuotaView(
            model: model,
            refresh: { [weak self] in self?.model.refresh() },
            dismiss: { [weak self] in self?.closePopover() }
        ))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hostingController
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialStatusView = QuotaStatusView(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
        let initialWidth = initialStatusView.preferredWidth
        initialStatusView.setFrameSize(NSSize(width: initialWidth, height: 22))
        statusView = initialStatusView
        statusView.onLeftClick = { [weak self] in self?.togglePopover() }
        statusView.onRightClick = { [weak self] in self?.showStatusMenu() }
        statusItem.view = statusView
        statusItem.length = initialWidth

        let show = NSMenuItem(title: "显示额度", action: #selector(showPopover), keyEquivalent: "")
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshQuota), keyEquivalent: "")
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        [show, refresh, NSMenuItem.separator(), quit].forEach { item in
            item.target = self
            statusMenu.addItem(item)
        }
    }

    private func showStatusMenu() {
        closePopover()
        statusMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func installPopoverDismissMonitors() {
        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            self?.dismissPopoverForLocalClick()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissPopoverForGlobalClick()
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func dismissPopoverForLocalClick() {
        guard popover.isShown else { return }
        let clickLocation = NSEvent.mouseLocation

        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(clickLocation) {
            return
        }

        if isClickInStatusItem(clickLocation) {
            return
        }

        closePopover()
    }

    private func dismissPopoverForGlobalClick() {
        guard popover.isShown else { return }
        if isClickInStatusItem(NSEvent.mouseLocation) { return }
        closePopover()
    }

    private func isClickInStatusItem(_ clickLocation: NSPoint) -> Bool {
        guard let statusWindow = statusView.window else { return false }
        let statusRect = statusView.convert(statusView.bounds, to: nil)
        return statusWindow.convertToScreen(statusRect).contains(clickLocation)
    }

    private func updateStatusItem() {
        guard let statusView else { return }
        let value = model.snapshot ?? model.fallbackSnapshot
        if let value {
            statusView.update(primary: value.primary.remaining, secondary: value.secondary.remaining, sourceName: value.sourceName)
        } else {
            statusView.update(primary: nil, secondary: nil, sourceName: nil)
        }

        let width = statusView.preferredWidth
        if statusItem.length != width {
            statusView.setFrameSize(NSSize(width: width, height: statusView.frame.height))
            statusItem.length = width
            statusView.needsLayout = true
        }
    }

    @objc private func showPopover() {
        guard let statusView else { return }
        if !popover.isShown {
            popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
        }
    }

    @objc private func closePopover() {
        popover.performClose(nil)
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    @objc private func refreshQuota() {
        model.refresh()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

func runProbe() -> Int32 {
    let client = CodexAppServerClient()
    let semaphore = DispatchSemaphore(value: 0)
    var snapshot: QuotaSnapshot?
    client.onSnapshot = {
        snapshot = $0
        semaphore.signal()
    }
    client.refresh()
    _ = semaphore.wait(timeout: .now() + 8)

    if let snapshot {
        let result: [String: Any] = [
            "Status": "ok",
            "PlanType": snapshot.planType as Any,
            "FiveHourRemain": snapshot.primary.remaining as Any,
            "WeeklyRemain": snapshot.secondary.remaining as Any,
            "SampledAt": ISO8601DateFormatter().string(from: snapshot.sampledAt),
            "SourceName": snapshot.sourceName
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        client.stop()
        return 0
    }

    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    if let fallback = SnapshotLoader.load(root: root) {
        let result: [String: Any] = [
            "Status": "ok",
            "PlanType": fallback.planType as Any,
            "FiveHourRemain": fallback.primary.remaining as Any,
            "WeeklyRemain": fallback.secondary.remaining as Any,
            "SampledAt": ISO8601DateFormatter().string(from: fallback.sampledAt),
            "SourceName": fallback.sourceName
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        client.stop()
        return 0
    }

    let result = ["Status": "unavailable", "Message": client.currentError.isEmpty ? "没有找到可读取的 Codex 限额快照" : client.currentError]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    client.stop()
    return 1
}

@main
struct ChatGPTQuotaPetMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            Foundation.exit(runProbe())
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
