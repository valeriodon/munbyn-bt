import AppKit
import ServiceManagement

/// The pieces of setup: the CUPS queue (one admin password), the login item and the
/// print dialog's default paper size. The setup assistant (Wizard.swift) drives them.
enum Setup {
    static let queueName = "MUNBYN_ITPP130B"
    static let queueTitle = "MUNBYN ITPP130B (Bluetooth)"

    static var supportDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MunbynBT")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // `lpstat` is slow when cupsd starts on demand, so the menu reads a cached answer.
    private static let cacheLock = NSLock()
    private static var cachedInstalled: Bool?

    /// Last known answer; refreshes in the background when it's unknown.
    static var printerInstalledCached: Bool {
        cacheLock.lock()
        let value = cachedInstalled
        cacheLock.unlock()
        if value == nil { refreshPrinterInstalled() }
        return value ?? true
    }

    static func refreshPrinterInstalled(port: UInt16 = 9100, then: ((Bool) -> Void)? = nil) {
        if demoOverride { return }
        DispatchQueue.global(qos: .utility).async {
            let installed = printerInstalled(port: port)
            cacheLock.lock()
            let changed = cachedInstalled != installed
            cachedInstalled = installed
            cacheLock.unlock()
            if changed { StatusCenter.shared.update { _ in } }
            if let then { DispatchQueue.main.async { then(installed) } }
        }
    }

    /// Used by the CI screenshots, which have no queue to check.
    static func overrideInstalled(_ value: Bool) {
        cacheLock.lock(); cachedInstalled = value; cacheLock.unlock()
        demoOverride = true
    }
    private static var demoOverride = false

    /// True when the queue exists and points to this app's local port.
    static func printerInstalled(port: UInt16 = 9100) -> Bool {
        let (status, output) = run("/usr/bin/lpstat", ["-v", queueName])
        return status == 0 && output.contains("socket://127.0.0.1:\(port)")
    }

    /// Setup is complete when the printer is in Printers & Scanners and MunbynBT knows which printer to use.
    static var isComplete: Bool { printerInstalledCached && Settings.printerID != nil }

    /// Adds the queue. Blocks while the macOS password prompt is open: call it off the main queue.
    static func installPrinter(port: UInt16 = 9100) throws {
        let ppdURL = supportDirectory.appendingPathComponent("munbyn.ppd")
        try ppd(defaultLabel: Settings.label).write(to: ppdURL, atomically: true, encoding: .isoLatin1)
        let command = "/usr/sbin/lpadmin -x \(queueName) 2>/dev/null; "
            + "/usr/sbin/lpadmin -p \(queueName) -E -D '\(queueTitle)' -L 'Bluetooth' "
            + "-v socket://127.0.0.1:\(port) -P \(shellQuoted(ppdURL.path)) -o printer-is-shared=false"
        let script = "do shell script \(appleScriptQuoted(command)) "
            + "with prompt \"MunbynBT wants to add the MUNBYN printer to Printers & Scanners.\" "
            + "with administrator privileges"
        let (status, output) = run("/usr/bin/osascript", ["-e", script])
        if status != 0 {
            if output.contains("-128") { throw CancelledByUser() }
            throw UserError.printerNotAdded.with(details: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        say("Printer queue \(queueName) added")
        cacheLock.lock(); cachedInstalled = true; cacheLock.unlock()
        syncDefaultPageSize()
    }

    struct CancelledByUser: Error {}

    /// Makes the print dialog default to the label size chosen in MunbynBT (per user, no password).
    static func syncDefaultPageSize() {
        let label = Settings.label
        guard let media = labelMedia.first(where: { abs($0.mm.w - label.w) < 0.5 && abs($0.mm.h - label.h) < 0.5 }) else { return }
        DispatchQueue.global(qos: .utility).async {
            run("/usr/bin/lpoptions", ["-p", queueName, "-o", "PageSize=\(media.key)"])
        }
    }

    static var opensAtLogin: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    /// Returns false when macOS wants the person to approve the login item in System Settings.
    @discardableResult
    static func setOpensAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13, *) else { return false }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            say("Login item: \(error)")
            if enabled && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return false
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Opens System Settings at the right pane.
enum SystemSettings {
    static func open(_ recovery: Recovery) {
        let urls: [String]
        switch recovery {
        case .openBluetoothSettings:
            urls = ["x-apple.systempreferences:com.apple.BluetoothSettings", "x-apple.systempreferences:com.apple.preferences.Bluetooth"]
        case .openPrivacySettings:
            urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]
        default:
            return
        }
        for u in urls {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openPrinters() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!
        if !NSWorkspace.shared.open(modern) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/PrintAndFax.prefPane"))
        }
    }
}
