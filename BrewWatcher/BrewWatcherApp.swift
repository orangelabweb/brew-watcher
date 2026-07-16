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
    /// `brew outdated` lists pinned packages, but `brew upgrade` skips them.
    /// Acting on this is what keeps a pinned package from becoming a badge
    /// that never clears — the same asymmetry trap as `--greedy`.
    let pinned: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        installedVersions = try c.decodeIfPresent([String].self, forKey: .installedVersions) ?? []
        currentVersion = try c.decode(String.self, forKey: .currentVersion)
        // Defaulted rather than required: if brew ever drops the field, treat
        // everything as upgradeable instead of decoding nothing at all.
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

struct OutdatedResponse: Decodable {
    let formulae: [OutdatedPackage]
    let casks: [OutdatedPackage]
}

struct UpgradeProgress {
    /// Starts as the outdated count, which is only ever a *lower bound* — see
    /// `markPackageCompleted()`. Never assign `completed` past this directly.
    private(set) var total: Int
    private(set) var completed: Int = 0
    var currentPackage: String?
    var status: LocalizedStringResource = "Starting..."
    var packagePercent: Double?

    init(total: Int) { self.total = total }

    /// `brew upgrade` does more than the outdated list implies: it pours
    /// brand-new dependencies, and upgrades installed dependents that were
    /// never outdated themselves. Both emit 🍺, so `completed` can pass the
    /// initial total. Grow the total instead of rendering "7/3" or a bar past
    /// full — an honest count that lands on 100% beats an impossible one.
    mutating func markPackageCompleted() {
        completed += 1
        total = max(total, completed)
    }

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

private nonisolated final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

/// Tracks the events that must all land before a `runBrew` continuation may
/// resume: stdout EOF, stderr EOF, and process exit.
///
/// Waiting on process exit alone truncates output, because the pipes can still
/// hold buffered bytes. Waiting on the pipes alone can hang forever, because
/// brew's grandchildren (git, curl) inherit the write ends and may outlive
/// brew. So we wait for all three, and let a timeout override the whole thing.
///
/// Exactly one caller ever gets `true` back, which makes double-resume — a
/// hard crash in Swift — structurally impossible.
private nonisolated final class CompletionLatch: @unchecked Sendable {
    enum Event { case stdoutEOF, stderrEOF, exit }

    private let lock = NSLock()
    private var pending: Set<Event> = [.stdoutEOF, .stderrEOF, .exit]
    private var resumed = false

    /// Marks `event` done. Returns true only to the caller that completes the set.
    func complete(_ event: Event) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending.remove(event)
        guard pending.isEmpty, !resumed else { return false }
        resumed = true
        return true
    }

    /// Abandons the remaining events (timeout path). Returns true only if
    /// nothing has resumed yet.
    func abandon() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
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
    @Published private(set) var launchAtLogin: Bool = false
    /// Set when an upgrade dies on a sudo prompt we can't answer, which is the
    /// one failure the user can actually resolve — in Terminal.
    @Published private(set) var needsTerminalUpgrade = false

    /// Tripped by the upgrade line stream. `runBrewStreaming` throws away
    /// stderr, so the sudo diagnosis has to be made while lines flow past.
    private var sawSudoFailure = false

    private var timer: Timer?
    private var installPollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let checkInterval: TimeInterval = 6 * 60 * 60
    private let upgradeTimeout: TimeInterval = 60 * 60
    /// Backstop for the short-running brew commands. Generous enough that a slow
    /// `brew update` on a bad connection still finishes; short enough that a
    /// stalled one can't disable checking until the app is relaunched.
    private let commandTimeout: TimeInterval = 10 * 60

    private let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private var cachedBrewPath: String?

    private static let notifiedNamesKey = "previouslyNotifiedNames"

    /// Set of package names from the previous check. Persisted so we don't
    /// re-notify for the same outdated packages after a relaunch.
    private var previouslyNotifiedNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.notifiedNamesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.notifiedNamesKey) }
    }

    private var brewPath: String? {
        if let cached = cachedBrewPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        cachedBrewPath = candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
        return cachedBrewPath
    }

    init() {
        if candidatePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            brewState = .ready
            Task { await startupCheck() }
        } else {
            brewState = .notInstalled
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
    }

    deinit {
        timer?.invalidate()
        installPollTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func handleWake() {
        guard brewState == .ready else { return }
        let last = lastChecked ?? .distantPast
        if Date().timeIntervalSince(last) >= checkInterval {
            Task { await check() }
        }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ newValue: Bool) {
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
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            errorMessage = String(localized: "Couldn't change launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
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

    /// Opens Terminal.app and runs `command` in a new window.
    ///
    /// Terminal is where anything needing a password happens: the user sees the
    /// exact command and types their own sudo password into a real tty. The app
    /// never brokers credentials.
    private func runInTerminal(_ command: String) throws {
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.escapeAppleScript(command))"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try task.run()
    }

    /// Opens Terminal.app and runs the official brew install script.
    /// The user sees exactly what runs, enters their sudo password in Terminal,
    /// and the app polls in the background until brew appears on disk.
    func installBrew() {
        brewState = .installing
        errorMessage = nil

        let installCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

        do {
            try runInTerminal(installCommand)
            startPollingForBrew()
        } catch {
            errorMessage = String(localized: "Couldn't open Terminal: \(error.localizedDescription)")
            brewState = .notInstalled
        }
    }

    /// Hands the upgrade to Terminal after a sudo prompt blocked us. Casks with
    /// pkg installers need root, and a GUI app has no controlling tty for sudo
    /// to prompt on.
    func upgradeInTerminal() {
        guard let brewPath else { return }
        do {
            try runInTerminal("\(brewPath) upgrade")
            needsTerminalUpgrade = false
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn't open Terminal: \(error.localizedDescription)")
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
        guard !isChecking, brewPath != nil else { return }
        isChecking = true
        clearError()
        defer { isChecking = false }

        do {
            _ = try await runBrew(["update", "--quiet"], timeout: commandTimeout)
            let data = try await runBrew(["outdated", "--json=v2"], timeout: commandTimeout)
            let response = try JSONDecoder().decode(OutdatedResponse.self, from: data)
            // Pinned packages are excluded deliberately: brew upgrade won't touch
            // them, so counting them would badge the menu bar with work that no
            // amount of clicking "Upgrade all" can ever clear.
            outdated = (response.formulae + response.casks).filter { !$0.pinned }
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
        clearError()
        sawSudoFailure = false
        progress = UpgradeProgress(total: outdated.count)
        defer {
            isUpgrading = false
            progress = nil
        }

        do {
            try await runBrewStreaming(["upgrade", "--verbose"], timeout: upgradeTimeout) { [weak self] line in
                self?.handleUpgradeLine(line)
            }
            _ = try await runBrew(["cleanup"], timeout: commandTimeout)
            await check()
        } catch {
            // Refresh before reporting: brew works through packages one at a
            // time, so a run that died on package 4 of 6 still upgraded three.
            // The list has to show what's actually installed now.
            await check()
            if sawSudoFailure {
                errorMessage = String(localized: "Some packages need administrator rights. Upgrade in Terminal to enter your password.")
                needsTerminalUpgrade = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// `needsTerminalUpgrade` only ever qualifies the message in `errorMessage`,
    /// so the two must be cleared together or the Terminal button outlives the
    /// error that justified it and reappears attached to an unrelated one.
    private func clearError() {
        errorMessage = nil
        needsTerminalUpgrade = false
    }

    private func handleUpgradeLine(_ line: String) {
        if Self.indicatesSudoFailure(line) { sawSudoFailure = true }
        parseUpgradeLine(line)
    }

    /// Detects brew hitting a sudo prompt it can't display. Homebrew only passes
    /// `sudo -A` when `SUDO_ASKPASS` is set; without it, sudo needs a tty that a
    /// menu bar app doesn't have, and emits:
    ///   "sudo: a terminal is required to read the password..."
    ///   "sudo: a password is required"
    /// Matched loosely on purpose — sudo's wording is no more of an API than
    /// brew's, and a false positive only offers a Terminal button the user can
    /// ignore.
    private static func indicatesSudoFailure(_ line: String) -> Bool {
        let l = line.lowercased()
        guard l.contains("sudo") || l.contains("askpass") else { return false }
        return l.contains("terminal is required")
            || l.contains("password is required")
            || l.contains("no tty present")
            || l.contains("askpass")
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
            progress?.markPackageCompleted()
            progress?.packagePercent = nil
            progress?.status = "Done"
        }

        // Skip percent parse on status-marker lines so a stray `%` in
        // a `==> ...` line doesn't override a freshly-cleared percent.
        if !clean.hasPrefix("==>"), let regex = Self.percentRegex {
            let range = NSRange(clean.startIndex..., in: clean)
            if let match = regex.firstMatch(in: clean, range: range),
               let r = Range(match.range(at: 1), in: clean),
               let pct = Double(clean[r]) {
                progress?.packagePercent = pct
            }
        }
    }

    // MARK: - Subprocess

    /// Runs brew to completion and returns stdout.
    ///
    /// `timeout` is a backstop, not a tuning knob: without it a stalled `brew
    /// update` (git fetch has no network timeout of its own) would strand the
    /// continuation, leaving `isChecking` true forever and killing every future
    /// check until relaunch.
    private func runBrew(_ args: [String], timeout: TimeInterval? = nil) async throws -> Data {
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
            let latch = CompletionLatch()
            let timedOut = TimeoutFlag()

            let timeoutError = NSError(domain: "Brew", code: -2,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "brew \(argString) timed out")])

            let finish = {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let finalOut = outAcc.drain()
                let finalErr = errAcc.drain()

                // Check this before terminationStatus: a timeout that lands as
                // SIGTERM would otherwise surface as a generic "failed".
                if timedOut.value {
                    continuation.resume(throwing: timeoutError)
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: finalOut)
                } else {
                    let stderr = String(data: finalErr, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let msg = stderr.isEmpty ? String(localized: "brew \(argString) failed") : stderr
                    continuation.resume(throwing: NSError(domain: "Brew",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }

            // An empty read means EOF: the write end is closed everywhere.
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    if latch.complete(.stdoutEOF) { finish() }
                } else {
                    outAcc.append(d)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    if latch.complete(.stderrEOF) { finish() }
                } else {
                    errAcc.append(d)
                }
            }

            process.terminationHandler = { _ in
                if latch.complete(.exit) { finish() }
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                    // Deliberately not guarded on isRunning: an exited brew whose
                    // grandchild still holds the pipes open leaves EOF pending,
                    // and that path needs the abandon below just as much.
                    if let process, process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak process] in
                        if let process, process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        // No-op once finish() has run; abandon() yields true at
                        // most once, so this can't double-resume.
                        if latch.abandon() { continuation.resume(throwing: timeoutError) }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                if latch.abandon() { continuation.resume(throwing: error) }
            }
        }
    }

    private func runBrewStreaming(_ args: [String],
                                  timeout: TimeInterval? = nil,
                                  onLine: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let process = makeProcess(args: args) else {
                cont.resume(throwing: NSError(domain: "Brew", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Homebrew not found")]))
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

            let timedOut = TimeoutFlag()
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else if timedOut.value {
                    cont.resume(throwing: NSError(domain: "Brew", code: -2,
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "Upgrade timed out")]))
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
        let safeTitle = Self.escapeAppleScript(title)
        let safeBody = Self.escapeAppleScript(body)
        let script = #"display notification "\#(safeBody)" with title "\#(safeTitle)" sound name "Glass""#
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
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
            // A banner, not a replacement for `content`: a failed check says
            // nothing about the packages we already know are outdated, and
            // hiding them is the opposite of what an error should do.
            if let error = brew.errorMessage {
                errorBanner(error)
                Divider()
            }
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

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if brew.needsTerminalUpgrade {
                Button("Upgrade in Terminal") { brew.upgradeInTerminal() }
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        if brew.isUpgrading {
            Text("Upgrading...")
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .center)
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
                set: { brew.setLaunchAtLogin($0) }
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
