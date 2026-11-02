import AppKit
import UniformTypeIdentifiers

/// Starts the server for CUPS and, when there is a GUI session, the menu bar panel.
func runApp(_ opts: Options) -> Never {
    if opts.dryRunDir == nil {
        _ = sharedPrinter(opts)  // asks for Bluetooth permission right away on first launch
    }
    JobServer(port: opts.port, options: opts).start()
    if opts.headless { dispatchMain() }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(opts: opts)
    if opts.dryRunDir == nil {
        DispatchQueue.main.async { Setup.firstRun(port: opts.port) }
    }
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let opts: Options

    init(opts: Options) {
        self.opts = opts
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()
        StatusCenter.shared.onChange = { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        if opts.showMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item.button?.performClick(nil) }
        }
    }

    private func updateIcon() {
        let s = StatusCenter.shared.snapshot()
        let symbol = s.error ? "exclamationmark.triangle" : (s.busy ? "printer.fill" : "printer")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MUNBYN")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "MUNBYN ITPP130B · \(s.state)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = StatusCenter.shared.snapshot()
        menu.removeAllItems()

        menu.addItem(info("MUNBYN ITPP130B via Bluetooth", bold: true))
        menu.addItem(info("Status: \(s.state)"))
        menu.addItem(info("Last print: \(s.lastJob)"))
        menu.addItem(info("Printer: \(Settings.printerName ?? "not connected yet")"))
        menu.addItem(.separator())

        let sizes = NSMenu()
        let current = Settings.label
        for m in labelMedia {
            let it = action(m.name, #selector(setLabel(_:)))
            it.representedObject = sizeName(m.mm)
            it.state = abs(m.mm.w - current.w) < 0.5 && abs(m.mm.h - current.h) < 0.5 ? .on : .off
            sizes.addItem(it)
        }
        menu.addItem(submenu("Label size: \(labelName(current))", sizes))

        let density = NSMenu()
        for v in 1...15 {
            let it = action(v == 8 ? "\(v) (default)" : "\(v)", #selector(setDensity(_:)))
            it.tag = v
            it.state = v == Settings.density ? .on : .off
            density.addItem(it)
        }
        menu.addItem(submenu("Density: \(Settings.density)", density))

        let speed = NSMenu()
        for v in 1...6 {
            let it = action(v == 4 ? "\(v) (default)" : "\(v)", #selector(setSpeed(_:)))
            it.tag = v
            it.state = v == Settings.speed ? .on : .off
            speed.addItem(it)
        }
        menu.addItem(submenu("Speed: \(Settings.speed)", speed))

        let trim = action("Crop white margins", #selector(toggleTrim))
        trim.state = Settings.trim ? .on : .off
        trim.toolTip = "Crops the content (for example a label on an A4 sheet) and fits it to the label"
        menu.addItem(trim)
        let dither = action("Dithering for photos", #selector(toggleDither))
        dither.state = Settings.dither ? .on : .off
        menu.addItem(dither)
        menu.addItem(.separator())

        menu.addItem(action("Print a PDF or Image…", #selector(printFile), enabled: !s.busy))
        menu.addItem(action("Print a Test Label", #selector(printTest), enabled: !s.busy))
        menu.addItem(action("Print the Self-Test Page", #selector(selfTest), enabled: !s.busy))
        menu.addItem(action("Check Connection", #selector(checkConnection), enabled: !s.busy))

        let printers = NSMenu()
        printers.addItem(action("Search for Nearby Printers", #selector(scan), enabled: !s.busy))
        if !s.nearby.isEmpty {
            printers.addItem(.separator())
            for d in s.nearby {
                let it = action("\(d.name)  (\(d.rssi) dBm)", #selector(choosePrinter(_:)))
                it.representedObject = [d.id.uuidString, d.name]
                it.state = d.id == Settings.printerID ? .on : .off
                printers.addItem(it)
            }
        }
        printers.addItem(.separator())
        printers.addItem(action("Forget This Printer", #selector(forgetPrinter), enabled: Settings.printerID != nil))
        menu.addItem(submenu("Bluetooth Printer", printers))
        menu.addItem(.separator())

        if !Setup.printerInstalled(port: opts.port) {
            menu.addItem(action("Add the Printer to Printers & Scanners…", #selector(addPrinter)))
        }
        menu.addItem(action("Open Printers & Scanners", #selector(openPrinters)))
        if #available(macOS 13, *) {
            let login = action("Open at Login", #selector(toggleLogin))
            login.state = Setup.opensAtLogin ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(info("munbyn-bt \(appVersion)"))
        menu.addItem(action("Quit", #selector(quit)))
    }

    private func labelName(_ l: LabelSize) -> String {
        labelMedia.first { abs($0.mm.w - l.w) < 0.5 && abs($0.mm.h - l.h) < 0.5 }?.name ?? "\(sizeName(l)) mm"
    }

    private func info(_ title: String, bold: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        if bold {
            it.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        return it
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    // MARK: Actions

    @objc private func setLabel(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let l = parseSize(s) { Settings.label = l }
    }

    @objc private func setDensity(_ sender: NSMenuItem) { Settings.density = sender.tag }
    @objc private func setSpeed(_ sender: NSMenuItem) { Settings.speed = sender.tag }
    @objc private func toggleTrim() { Settings.trim.toggle() }
    @objc private func toggleDither() { Settings.dither.toggle() }

    private func jobOptions() -> Options {
        var o = Options.fromSettings()
        o.names = opts.names
        return o
    }

    @objc private func printFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose the label to print"
        panel.prompt = "Print"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let o = jobOptions()
        jobQueue.async {
            do {
                let data = try Data(contentsOf: url)
                runJobReporting(data: data, opts: o, title: url.lastPathComponent)
            } catch {
                notify("Can't read the file", "\(error)")
            }
        }
    }

    @objc private func printTest() {
        let o = jobOptions()
        jobQueue.async {
            runJobReporting(data: makeTestPDF(label: o.fallbackLabel, onA4: false), opts: o, title: "test label")
        }
    }

    @objc private func selfTest() {
        let o = jobOptions()
        background("Self-test") {
            try deliver([Data("REFERENCE 0,0\nSELFTEST\n".utf8)], opts: o)
            return "Ready"
        }
    }

    @objc private func checkConnection() {
        let o = jobOptions()
        background("Connection check") {
            let ble = sharedPrinter(o)
            let info = try ble.connect(savedID: Settings.printerID)
            Settings.printerID = info.id
            Settings.printerName = info.name
            ble.disconnect()
            return "Connected to \(info.name)"
        }
    }

    @objc private func scan() {
        let o = jobOptions()
        StatusCenter.shared.update { $0.state = "Searching for printers (10 s)…" }
        background("Search") {
            let found = try sharedPrinter(o).scanAll(seconds: 10)
            StatusCenter.shared.update { $0.nearby = found }
            let printers = found.filter { $0.match }.count
            return found.isEmpty ? "No devices found" : "Found \(printers) printer(s) among \(found.count) devices: pick one under Bluetooth Printer"
        }
    }

    @objc private func choosePrinter(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else { return }
        Settings.printerID = UUID(uuidString: values[0])
        Settings.printerName = values[1]
    }

    @objc private func forgetPrinter() {
        Settings.printerID = nil
        Settings.printerName = nil
    }

    @objc private func openPrinters() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!
        if !NSWorkspace.shared.open(modern) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/PrintAndFax.prefPane"))
        }
    }

    @objc private func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/munbyn-bt.log")
        NSWorkspace.shared.open(log)
    }

    @objc private func addPrinter() {
        NSApp.activate(ignoringOtherApps: true)
        Setup.addPrinterReporting(port: opts.port)
    }

    @objc private func toggleLogin() { Setup.setOpensAtLogin(!Setup.opensAtLogin) }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Runs an operation on the print queue, keeping the status up to date.
    private func background(_ title: String, _ work: @escaping () throws -> String) {
        StatusCenter.shared.update {
            $0.busy = true
            $0.error = false
        }
        jobQueue.async {
            do {
                let result = try work()
                StatusCenter.shared.update {
                    $0.busy = false
                    $0.state = result
                }
            } catch {
                StatusCenter.shared.update {
                    $0.busy = false
                    $0.error = true
                    $0.state = "Error: \(error)"
                }
                notify("\(title) failed", "\(error)")
            }
        }
    }
}
