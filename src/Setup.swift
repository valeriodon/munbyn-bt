import AppKit
import ServiceManagement

/// First-run setup, so the app works when it's simply dragged out of the DMG:
/// adds the CUPS queue (asking for an admin password once) and opens at login.
enum Setup {
    static let queueName = "MUNBYN_ITPP130B"

    static var supportDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MunbynBT")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when the queue exists and points to this app's local port.
    static func printerInstalled(port: UInt16) -> Bool {
        let (status, output) = run("/usr/bin/lpstat", ["-v", queueName])
        return status == 0 && output.contains("socket://127.0.0.1:\(port)")
    }

    static func installPrinter(port: UInt16) throws {
        let ppdURL = supportDirectory.appendingPathComponent("munbyn.ppd")
        try ppd(defaultLabel: Settings.label).write(to: ppdURL, atomically: true, encoding: .utf8)
        let command = "/usr/sbin/lpadmin -x \(queueName) 2>/dev/null; "
            + "/usr/sbin/lpadmin -p \(queueName) -E -D 'MUNBYN ITPP130B (Bluetooth)' -L 'Bluetooth' "
            + "-v socket://127.0.0.1:\(port) -P \(shellQuoted(ppdURL.path)) -o printer-is-shared=false"
        let script = "do shell script \(appleScriptQuoted(command)) "
            + "with prompt \"MunbynBT wants to add the MUNBYN printer to Printers & Scanners.\" "
            + "with administrator privileges"
        let (status, output) = run("/usr/bin/osascript", ["-e", script])
        if status != 0 {
            throw Failure(output.contains("-128") ? "Cancelled" : "Couldn't add the printer: \(output)")
        }
        say("Printer queue \(queueName) added")
    }

    static var opensAtLogin: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func setOpensAtLogin(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            say("Login item: \(error)")
        }
    }

    /// Shown once, at the first launch from the GUI.
    static func firstRun(port: UInt16) {
        guard !Settings.store.bool(forKey: "setupDone") else { return }
        let needsPrinter = !printerInstalled(port: port)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to MunbynBT"
        alert.informativeText = needsPrinter
            ? "MunbynBT adds \"MUNBYN ITPP130B (Bluetooth)\" to Printers & Scanners so you can print labels from any app. macOS will ask for your password.\n\nSettings and status live in the printer icon in the menu bar."
            : "The printer is ready. Settings and status live in the printer icon in the menu bar."
        alert.addButton(withTitle: needsPrinter ? "Add Printer" : "OK")
        if needsPrinter { alert.addButton(withTitle: "Not Now") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Open MunbynBT at login"
        alert.suppressionButton?.state = .on
        let response = alert.runModal()
        setOpensAtLogin(alert.suppressionButton?.state == .on)
        Settings.store.set(true, forKey: "setupDone")
        if needsPrinter && response == .alertFirstButtonReturn { addPrinterReporting(port: port) }
    }

    static func addPrinterReporting(port: UInt16) {
        do {
            try installPrinter(port: port)
            StatusCenter.shared.update { $0.state = "Printer added: choose \"MUNBYN ITPP130B (Bluetooth)\" when printing" }
        } catch {
            if "\(error)" == "Cancelled" { return }
            let alert = NSAlert()
            alert.messageText = "The printer wasn't added"
            alert.informativeText = "\(error)"
            alert.runModal()
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
