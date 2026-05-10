import SwiftUI
import Combine
import ServiceManagement

// MARK: - App

@main
struct BrewWatcherApp: App {
    @StateObject private var brew = BrewMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuView(brew: brew)
        } label: {
            Label {
                Text(brew.outdated.isEmpty ? "" : "\(brew.outdated.count)")
            } icon: {
                Image(systemName: iconName)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        switch brew.brewState {
        case .notInstalled: return "exclamationmark.triangle.fill"
        case .installing:   return "arrow.down.circle"
        case .ready:        return brew.outdated.isEmpty ? "mug" : "mug.fill"
        }
    }
}

// MARK: - Models

struct OutdatedPackage: Identifiable, Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

struct OutdatedResponse: Decodable {
    let formulae: [OutdatedPackage]
    let casks: [OutdatedPackage]
}

struct UpgradeProgress {
    var total: Int
    var completed: Int = 0
    var currentPackage: String?
    var status: LocalizedStringResource = "Starting..."
    var packagePercent: Double?

    var overallFraction: Double {
        guard total > 0 else { return 0 }
        var base = Double(completed) / Double(total)
        if let pct = packagePercent {
            base += (pct / 100.0) / Double(total)
        }
        return min(base, 1.0)
    }
}

enum BrewState: Equatable {
    case notInstalled
    case installing
    case ready
}

// MARK: - Line Buffer

private nonisolated final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        while let idx = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[..<idx]
            data.removeSubrange(...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                onLine(line)
            }
        }
    }
}

/// Thread-safe Data accumulator used by `runBrew` to drain stdout/stderr from
/// readability handlers without capturing a mutable `var` across actor boundaries.
private nonisolated final class DataAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let out = data
        data = Data()
        return out
    }
}

// MARK: - Brew Monitor

@MainActor
final class BrewMonitor: ObservableObject {
    @Published var outdated: [OutdatedPackage] = []
    @Published var isChecking = false
    @Published var isUpgrading = false
    @Published var lastChecked: Date?
    @Published var errorMessage: String?
    @Published var progress: UpgradeProgress?
    @Published var brewState: BrewState

    private var timer: Timer?
    private var installPollTimer: Timer?
    private let checkInterval: TimeInterval = 6 * 60 * 60

    private let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private var cachedBrewPath: String?

    /// Set of package names from the previous check. Used to notify only on
    /// newly-outdated packages instead of pinging every 6h with the same list.
    private var previouslyNotifiedNames: Set<String> = []

    private var brewPath: String? {
        if let cached = cachedBrewPath { return cached }
        let resolved = candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
        cachedBrewPath = resolved
        return resolved
    }

    init() {
        if candidatePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            brewState = .ready
            Task { await startupCheck() }
        } else {
            brewState = .notInstalled
        }
    }

    deinit {
        timer?.invalidate()
        installPollTimer?.invalidate()
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                errorMessage = String(localized: "Couldn't change launch at login: \(error.localizedDescription)")
            }
        }
    }

    private func startupCheck() async {
        await check()
        scheduleRegularChecks()
    }

    private func scheduleRegularChecks() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    // MARK: - Installation

    /// Opens Terminal.app and runs the official brew install script.
    /// The user sees exactly what runs, enters their sudo password in Terminal,
    /// and the app polls in the background until brew appears on disk.
    func installBrew() {
        brewState = .installing
        errorMessage = nil

        let installCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

        // AppleScript that opens Terminal, focuses the window, and types the command.
        let script = """
        tell application "Terminal"
            activate
            do script "\(installCommand.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            startPollingForBrew()
        } catch {
            errorMessage = String(localized: "Couldn't open Terminal: \(error.localizedDescription)")
            brewState = .notInstalled
        }
    }

    /// Polls every 3 seconds for brew to appear on disk, with a 10-minute timeout.
    private func startPollingForBrew() {
        installPollTimer?.invalidate()
        let start = Date()
        let timeout: TimeInterval = 10 * 60

        installPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in
                // Invalidate the path cache so a freshly-installed brew is detected.
                self.cachedBrewPath = nil
                if self.brewPath != nil {
                    timer.invalidate()
                    self.installPollTimer = nil
                    self.brewState = .ready
                    await self.check()
                    self.notify(
                        title: String(localized: "Homebrew installed"),
                        body: String(localized: "BrewWatcher is ready to use")
                    )
                    self.scheduleRegularChecks()
                } else if Date().timeIntervalSince(start) > timeout {
                    timer.invalidate()
                    self.installPollTimer = nil
                    self.brewState = .notInstalled
                    self.errorMessage = String(localized: "Timed out. Press 'Install Homebrew' again to try once more.")
                }
            }
        }
    }

    func cancelInstallWait() {
        installPollTimer?.invalidate()
        installPollTimer = nil
        brewState = .notInstalled
    }

    // MARK: - Check / Upgrade

    func check() async {
        guard !isChecking, let _ = brewPath else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            _ = try await runBrew(["update", "--quiet"])
            let data = try await runBrew(["outdated", "--json=v2"])
            let response = try JSONDecoder().decode(OutdatedResponse.self, from: data)
            outdated = response.formulae + response.casks
            lastChecked = Date()

            let currentNames = Set(outdated.map(\.name))
            let newlyOutdated = currentNames.subtracting(previouslyNotifiedNames)
            previouslyNotifiedNames = currentNames
            if !newlyOutdated.isEmpty {
                let body: String
                if newlyOutdated.count == 1, let name = newlyOutdated.first {
                    body = String(localized: "\(name) can be updated")
                } else {
                    body = String(localized: "\(newlyOutdated.count) new packages can be updated")
                }
                notify(title: "Homebrew", body: body)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func upgradeAll() async {
        guard !isUpgrading, brewPath != nil else { return }
        isUpgrading = true
        progress = UpgradeProgress(total: outdated.count)
        defer {
            isUpgrading = false
            progress = nil
        }

        do {
            try await runBrewStreaming(["upgrade", "--verbose"]) { [weak self] line in
                self?.parseUpgradeLine(line)
            }
            _ = try await runBrew(["cleanup"])
            await check()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let percentRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)%"#)

    private func parseUpgradeLine(_ line: String) {
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, progress != nil else { return }

        if clean.hasPrefix("==> Fetching ") {
            let rest = String(clean.dropFirst("==> Fetching ".count))
                .replacingOccurrences(of: "dependencies for ", with: "")
            if let name = rest.split(whereSeparator: { $0 == " " || $0 == ":" }).first {
                progress?.currentPackage = String(name)
            }
            progress?.status = "Fetching"
            progress?.packagePercent = nil
        } else if clean.hasPrefix("==> Downloading") {
            progress?.status = "Downloading"
        } else if clean.hasPrefix("==> Upgrading ") && clean.contains("->") {
            let rest = String(clean.dropFirst("==> Upgrading ".count))
            if let name = rest.split(separator: " ").first {
                progress?.currentPackage = String(name)
            }
            progress?.status = "Preparing"
        } else if clean.hasPrefix("==> Pouring ") || clean.hasPrefix("==> Installing") {
            progress?.status = "Installing"
            progress?.packagePercent = nil
        } else if clean.contains("🍺") {
            progress?.completed += 1
            progress?.packagePercent = nil
            progress?.status = "Done"
        }

        if let regex = Self.percentRegex {
            let range = NSRange(clean.startIndex..., in: clean)
            if let match = regex.firstMatch(in: clean, range: range),
               let r = Range(match.range(at: 1), in: clean),
               let pct = Double(clean[r]) {
                progress?.packagePercent = pct
            }
        }
    }

    // MARK: - Subprocess

    private func runBrew(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard let process = makeProcess(args: args) else {
                continuation.resume(throwing: NSError(domain: "Brew", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Homebrew not found")]))
                return
            }
            let argString = args.joined(separator: " ")
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain pipes via readability handlers so the child never blocks on a full
            // 64KB pipe buffer while we wait for it to terminate.
            let outAcc = DataAccumulator()
            let errAcc = DataAccumulator()

            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty { outAcc.append(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty { errAcc.append(d) }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain any bytes the handler missed between the last fire and termination.
                outAcc.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errAcc.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let finalOut = outAcc.drain()
                let finalErr = errAcc.drain()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: finalOut)
                } else {
                    let msg = String(data: finalErr, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? String(localized: "brew \(argString) failed")
                    continuation.resume(throwing: NSError(domain: "Brew",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }

            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func runBrewStreaming(_ args: [String],
                                  onLine: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let process = makeProcess(args: args) else {
                cont.resume(throwing: NSError(domain: "Brew", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Homebrew hittades inte"]))
                return
            }
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let buffer = LineBuffer { line in
                Task { @MainActor in onLine(line) }
            }

            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty { buffer.append(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if !d.isEmpty { buffer.append(d) }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let argString = args.joined(separator: " ")
                    cont.resume(throwing: NSError(domain: "Brew",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "brew \(argString) failed")]))
                }
            }

            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func makeProcess(args: [String]) -> Process? {
        guard let path = brewPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let brewBin = (path as NSString).deletingLastPathComponent
        env["PATH"] = "\(brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        p.environment = env
        return p
    }

    private func notify(title: String, body: String) {
        let script = #"display notification "\#(body)" with title "\#(title)" sound name "Glass""#
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - View

struct MenuView: View {
    @ObservedObject var brew: BrewMonitor

    var body: some View {
        Group {
            switch brew.brewState {
            case .notInstalled: notInstalledView
            case .installing:   installingView
            case .ready:        readyView
            }
        }
        .frame(width: 340)
    }

    // MARK: Welcome / install

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "mug.fill")
                Text("Welcome to BrewWatcher").font(.headline)
            }

            Text("Homebrew doesn't appear to be installed. BrewWatcher needs it to work.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Clicking the button below opens Terminal with the official install script. You'll need to enter your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link("Learn more at brew.sh", destination: URL(string: "https://brew.sh")!)
                    .font(.caption)
                Spacer()
                Button("Install Homebrew") {
                    brew.installBrew()
                }
                .keyboardShortcut(.return)
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
    }

    private var installingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                Text("Installing Homebrew").font(.headline)
                Spacer()
                ProgressView().controlSize(.small)
            }

            Text("Finish the installation in the Terminal window. BrewWatcher will detect when Homebrew is ready.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let err = brew.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { brew.cancelInstallWait() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
    }

    // MARK: Normal mode

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let p = brew.progress {
                progressSection(p)
                Divider()
            }
            content
            Divider()
            actions
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "mug.fill")
            Text("Homebrew").font(.headline)
            Spacer()
            if brew.isChecking || brew.isUpgrading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func progressSection(_ p: UpgradeProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(p.completed)/\(p.total)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let pkg = p.currentPackage {
                    Text(pkg).font(.system(.caption, design: .monospaced))
                }
                Spacer()
                Text(p.status).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: p.overallFraction)
            if let pct = p.packagePercent {
                HStack(spacing: 6) {
                    ProgressView(value: pct, total: 100)
                    Text("\(Int(pct))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let error = brew.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(12)
        } else if brew.outdated.isEmpty {
            Group {
                if brew.lastChecked == nil {
                    Text("Checking...")
                } else {
                    Text("All up to date ✨")
                }
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(brew.outdated) { pkg in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pkg.name).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("\(pkg.installedVersions.first ?? "?") → \(pkg.currentVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                Task { await brew.check() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .disabled(brew.isChecking || brew.isUpgrading)

            Spacer()

            if !brew.outdated.isEmpty {
                Button {
                    Task { await brew.upgradeAll() }
                } label: {
                    if brew.isUpgrading {
                        Label("Updating...", systemImage: "arrow.up.circle.fill")
                    } else {
                        Label("Upgrade all", systemImage: "arrow.up.circle.fill")
                    }
                }
                .disabled(brew.isUpgrading || brew.isChecking)
                .keyboardShortcut(.return)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(
                get: { brew.launchAtLogin },
                set: { brew.launchAtLogin = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            if let last = brew.lastChecked {
                Text("Last: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
