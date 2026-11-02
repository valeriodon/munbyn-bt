import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Options the app was started with (printer names, dry run, demo flags).
var appOptions = Options()
private var menuController: MenuBarController?
private let appDelegate = AppDelegate()

/// Starts the server for CUPS and, when there is a GUI session, the menu bar panel.
func runApp(_ opts: Options) -> Never {
    appOptions = opts
    // Bluetooth is set up right away only if it's already allowed. Otherwise the
    // setup assistant asks for it, after explaining why.
    if opts.dryRunDir == nil && BLEPrinter.isAuthorized { _ = sharedPrinter(opts) }
    JobServer(port: opts.port, options: opts).start()
    if opts.headless { dispatchMain() }

    isAppMode = true
    if opts.dryRunDir == nil { redirectLogToFile() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = appDelegate
    if opts.demoDark { app.appearance = NSAppearance(named: .darkAqua) }
    Notifier.shared.setUp()
    Notifier.shared.onRecovery = { handle($0) }
    if let demo = opts.demoStatus { applyDemoStatus(demo) }
    Setup.refreshPrinterInstalled(port: opts.port)
    menuController = MenuBarController(opts: opts)

    if let step = opts.demoWizard {
        DispatchQueue.main.async { showDemoWizard(step) }
    } else if opts.dryRunDir == nil && !Settings.setupFinished && !Settings.setupDismissed {
        DispatchQueue.main.async { WizardWindow.shared.show() }
    }
    app.run()
    exit(0)
}

/// Started from Finder or as a login item, the app has no terminal: keep the log in
/// ~/Library/Logs (Help › Show Log), trimmed when it grows past 1 MB.
private func redirectLogToFile() {
    guard isatty(STDERR_FILENO) == 0 else { return }
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let path = logs.appendingPathComponent("munbyn-bt.log").path
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: path)
    }
    freopen(path, "a", stderr)
    say("MunbynBT \(appVersion) started")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the app again from Finder or Launchpad: the assistant if setup isn't
    /// finished, otherwise the menu (the icon can be hidden behind the notch).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Setup.isComplete { WizardWindow.shared.show() } else { menuController?.openMenu() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard StatusCenter.shared.snapshot().busy else { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit MunbynBT while a label is printing?"
        alert.informativeText = "The label stops printing, and other apps can’t print to the MUNBYN until you open MunbynBT again."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit and Stop Printing")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// What to do for each recovery, from the menu or a notification.
func handle(_ recovery: Recovery) {
    switch recovery {
    case .tryAgain:
        if hasFailedJob { retryLastFailedJob() } else { menuController?.checkConnection() }
    case .openBluetoothSettings, .openPrivacySettings:
        SystemSettings.open(recovery)
    case .changePrinter:
        WizardWindow.shared.show(at: .connect)
    case .runSetup:
        WizardWindow.shared.show()
    case .none:
        break
    }
}

// MARK: - Status text

/// The status in words, shared by the menu header, the icon's accessibility value and its tooltip.
struct StatusText {
    enum Action { case finishSetup, recovery(Recovery), cancelPrinting }

    var title: String
    var detail: String
    var progress: Double? = nil
    var problem = false
    var action: Action? = nil

    var spoken: String { detail.isEmpty ? title : "\(title). \(detail)" }

    static func current() -> StatusText {
        let s = StatusCenter.shared.snapshot()
        let name = Settings.printerName ?? "the printer"
        switch s.activity {
        case .preparing(let title):
            return StatusText(title: "Preparing \(title)…", detail: name)
        case .connecting:
            return StatusText(title: "Connecting to \(name)…", detail: "Keep the printer on and near your Mac.")
        case .printing(let index, let total, let fraction):
            return StatusText(title: total > 1 ? "Printing label \(index) of \(total)" : "Printing",
                              detail: "\(Int(fraction * 100))% sent to \(name)", progress: fraction, action: .cancelPrinting)
        case .searching:
            return StatusText(title: "Looking for printers…", detail: "This usually takes a few seconds.")
        case .checking:
            return StatusText(title: "Checking the connection…", detail: name)
        case .idle:
            break
        }
        if !Setup.printerInstalledCached {
            return StatusText(title: Settings.setupFinished ? "Not in your printers yet" : "Not set up yet",
                              detail: "Finish setup to print from any app.", problem: true, action: .finishSetup)
        }
        if let failure = s.lastError {
            let time = DateFormatter.localizedString(from: failure.date, dateStyle: .none, timeStyle: .short)
            let recovery = hasFailedJob && failure.error.recovery == .tryAgain ? Recovery.tryAgain : failure.error.recovery
            return StatusText(title: "Last label didn’t print", detail: "\(failure.error.title) · \(time)",
                              problem: true, action: recovery == .none ? nil : .recovery(recovery))
        }
        if Settings.printerID == nil {
            return StatusText(title: "No printer connected yet", detail: "Turn on your ITPP130B, then print a test label.",
                              action: .finishSetup)
        }
        var detail = name
        if let event = s.event {
            detail = event
        } else if let job = s.lastJob {
            let time = DateFormatter.localizedString(from: job.date, dateStyle: .none, timeStyle: .short)
            detail += " · last label \(time)"
        }
        return StatusText(title: "Ready to print", detail: detail)
    }
}

final class HeaderModel: ObservableObject {
    @Published var status = StatusText.current()
    func refresh() { status = StatusText.current() }
}

/// The first row of the menu: readable text (not a dimmed item), live while the menu is open.
struct HeaderView: View {
    @ObservedObject var model: HeaderModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.status.problem ? "exclamationmark.triangle.fill" : "printer")
                .font(.system(size: 18))
                .foregroundStyle(model.status.problem ? Color.orange : Color.primary)
                .frame(width: 24, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let p = model.status.progress {
                    ProgressView(value: p).controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.status.spoken)
    }
}

// MARK: - Menu

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let opts: Options
    private let header = HeaderModel()
    private lazy var headerItem: NSMenuItem = {
        let it = NSMenuItem()
        let host = NSHostingView(rootView: HeaderView(model: header))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        it.view = host
        return it
    }()

    init(opts: Options) {
        self.opts = opts
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("MunbynBT")
        updateIcon()
        StatusCenter.shared.observe { [weak self] in
            self?.updateIcon()
            self?.header.refresh()
            if let host = self?.headerItem.view { host.setFrameSize(host.fittingSize) }
        }
        if opts.showMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item.button?.performClick(nil) }
        }
    }

    func openMenu() { item.button?.performClick(nil) }

    private func updateIcon() {
        let s = StatusCenter.shared.snapshot()
        let status = StatusText.current()
        let badge: String? = s.hasUnseenError || (status.problem && s.lastError == nil) ? "exclamationmark.circle.fill" : nil
        item.button?.image = statusImage(printing: s.busy, badge: badge)
        if case .printing(_, _, let fraction) = s.activity {
            item.button?.title = " \(Int(fraction * 100))%"
            item.button?.imagePosition = .imageLeading
        } else {
            item.button?.title = ""
        }
        item.button?.toolTip = "MunbynBT · \(status.title)"
        item.button?.setAccessibilityValue(status.spoken)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if StatusCenter.shared.snapshot().hasUnseenError {
            StatusCenter.shared.update { $0.errorSeen = true }
        }
        Setup.refreshPrinterInstalled(port: opts.port)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = StatusCenter.shared.snapshot()
        let status = StatusText.current()
        header.refresh()
        menu.removeAllItems()

        menu.addItem(headerItem)
        if let action = status.action {
            switch action {
            case .finishSetup: menu.addItem(self.action("Finish Setup…", #selector(openSetup)))
            case .cancelPrinting: menu.addItem(self.action("Cancel Printing", #selector(cancelPrinting)))
            case .recovery(let r):
                if let title = r.buttonTitle {
                    let it = self.action(title, #selector(runRecovery(_:)))
                    it.representedObject = r.rawValue
                    menu.addItem(it)
                }
            }
        }
        menu.addItem(.separator())

        menu.addItem(self.action("Print PDF or Image…", #selector(printFile), key: "p"))
        menu.addItem(self.action("Print Test Label", #selector(printTest)))
        menu.addItem(.separator())

        menu.addItem(labelsItem())
        let crop = self.action("Crop and Fit to Label", #selector(toggleTrim))
        crop.state = Settings.trim ? .on : .off
        subtitle(crop, "Removes white margins")
        menu.addItem(crop)
        menu.addItem(qualityItem())
        menu.addItem(.separator())

        menu.addItem(printerItem(busy: s.busy))
        menu.addItem(helpItem())
        menu.addItem(.separator())

        if #available(macOS 13, *) {
            let login = self.action("Open at Login", #selector(toggleLogin))
            login.state = Setup.opensAtLogin ? .on : .off
            subtitle(login, "Needed to print")
            menu.addItem(login)
        }
        menu.addItem(self.action("About MunbynBT", #selector(about)))
        menu.addItem(self.action("Quit MunbynBT", #selector(quit), key: "q"))
    }

    private func labelsItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.addItem(sectionHeader("Labels loaded in the printer"))
        let current = Settings.label
        for m in labelMedia {
            let it = action(displayName(m), #selector(setLabel(_:)))
            it.representedObject = sizeName(m.mm)
            it.state = abs(m.mm.w - current.w) < 0.5 && abs(m.mm.h - current.h) < 0.5 ? .on : .off
            sub.addItem(it)
        }
        let item = submenu("Labels: \(labelName(current))", sub)
        subtitle(item, "Used for A4 and Letter pages")
        return item
    }

    private func qualityItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.addItem(sectionHeader("Darkness"))
        let darkness: [(String, Int)] = [("Lighter", 5), ("Normal", 8), ("Darker", 11), ("Darkest", 14)]
        for (name, value) in darkness {
            let it = action(name, #selector(setDensity(_:)))
            it.tag = value
            it.state = Settings.density == value ? .on : .off
            sub.addItem(it)
        }
        if !darkness.contains(where: { $0.1 == Settings.density }) {
            let it = action("Custom (\(Settings.density))", #selector(setDensity(_:)))
            it.tag = Settings.density
            it.state = .on
            sub.addItem(it)
        }
        sub.addItem(.separator())
        sub.addItem(sectionHeader("Speed"))
        let speeds: [(String, Int)] = [("Normal", 4), ("Slower, Sharper", 2)]
        for (name, value) in speeds {
            let it = action(name, #selector(setSpeed(_:)))
            it.tag = value
            it.state = Settings.speed == value ? .on : .off
            sub.addItem(it)
        }
        if !speeds.contains(where: { $0.1 == Settings.speed }) {
            let it = action("Custom (\(Settings.speed))", #selector(setSpeed(_:)))
            it.tag = Settings.speed
            it.state = .on
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let photos = action("Optimize for Photos", #selector(toggleDither))
        photos.state = Settings.dither ? .on : .off
        subtitle(photos, "Off for labels and barcodes")
        sub.addItem(photos)
        return submenu("Print Quality", sub)
    }

    private func printerItem(busy: Bool) -> NSMenuItem {
        let sub = NSMenu()
        if let name = Settings.printerName, Settings.printerID != nil {
            let it = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            it.state = .on
            it.isEnabled = false
            sub.addItem(it)
            sub.addItem(.separator())
        }
        sub.addItem(action("Search for Printers…", #selector(searchPrinters), enabled: !busy))
        sub.addItem(action("Check Connection", #selector(checkConnectionAction), enabled: !busy))
        sub.addItem(action("Print Printer Self-Test", #selector(selfTest), enabled: !busy))
        if let name = Settings.printerName, Settings.printerID != nil {
            sub.addItem(.separator())
            sub.addItem(action("Forget “\(name)”", #selector(forgetPrinter)))
        }
        return submenu("Printer: \(Settings.printerName ?? "None")", sub)
    }

    private func helpItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.addItem(action("Setup Assistant…", #selector(openSetup)))
        if !Setup.printerInstalledCached {
            sub.addItem(action("Add Printer to Printers & Scanners…", #selector(openAddStep)))
        }
        sub.addItem(action("Open Printers & Scanners", #selector(openPrinters)))
        sub.addItem(action("Show Log", #selector(openLog)))
        sub.addItem(action("MunbynBT on GitHub", #selector(openWebsite)))
        return submenu("Help", sub)
    }

    private func labelName(_ l: LabelSize) -> String {
        labelMedia.first { abs($0.mm.w - l.w) < 0.5 && abs($0.mm.h - l.h) < 0.5 }.map(displayName) ?? "\(sizeName(l).replacingOccurrences(of: "x", with: " × ")) mm"
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func subtitle(_ item: NSMenuItem, _ text: String) {
        #if compiler(>=5.10)  // the macOS 14.4 SDK, which has NSMenuItem.subtitle
        if #available(macOS 14.4, *) { item.subtitle = text; return }
        #endif
        item.toolTip = text
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: selector, keyEquivalent: key)
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
        if let s = sender.representedObject as? String, let l = parseSize(s) {
            Settings.label = l
            Setup.syncDefaultPageSize()
        }
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
        // Focus goes back to the app the person was using once the panel closes.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose the label to print"
        panel.prompt = "Print"
        let response = panel.runModal()
        previous?.activate()
        guard response == .OK, let url = panel.url else { return }
        let o = jobOptions()
        jobQueue.async {
            do {
                let data = try Data(contentsOf: url)
                runJobReporting(data: data, opts: o, title: url.deletingPathExtension().lastPathComponent)
            } catch {
                let e = UserError(title: "Couldn’t open “\(url.lastPathComponent)”",
                                  message: "Check that the file is still there, then choose it again.", recovery: .none)
                Notifier.shared.postFailure(e, jobTitle: url.lastPathComponent)
            }
        }
    }

    @objc private func printTest() {
        let o = jobOptions()
        jobQueue.async {
            runJobReporting(data: makeTestPDF(label: o.fallbackLabel, onA4: false, settings: testLabelFooter(o)), opts: o, title: "test label")
        }
    }

    @objc private func selfTest() {
        let o = jobOptions()
        jobQueue.async {
            do {
                try deliver([Data("REFERENCE 0,0\nSELFTEST\n".utf8)], opts: o)
                StatusCenter.shared.update { $0.activity = .idle; $0.event = "Self-test page sent" }
            } catch {
                let e = (error as? UserError) ?? UserError.noResponse
                StatusCenter.shared.update { $0.activity = .idle; $0.lastError = (Date(), e); $0.errorSeen = false }
                Notifier.shared.postFailure(e, jobTitle: "self-test")
            }
        }
    }

    @objc private func checkConnectionAction() { checkConnection() }

    func checkConnection() {
        let o = jobOptions()
        StatusCenter.shared.update { $0.activity = .checking; $0.event = nil }
        jobQueue.async {
            do {
                let ble = sharedPrinter(o)
                let info = try ble.connect(savedID: Settings.printerID)
                ble.disconnect()
                Settings.printerID = info.id
                Settings.printerName = info.name
                StatusCenter.shared.update { $0.activity = .idle; $0.lastError = nil; $0.event = "Connected just now" }
                Notifier.shared.postInfo("Printer connected", "\(info.name) is ready to print.")
                announce("Printer connected. \(info.name) is ready to print.")
            } catch {
                let e = (error as? UserError) ?? UserError.noResponse
                StatusCenter.shared.update { $0.activity = .idle; $0.lastError = (Date(), e); $0.errorSeen = false }
                Notifier.shared.postFailure(e, jobTitle: "connection check")
                announce("\(e.title). \(e.message)")
            }
        }
    }

    @objc private func searchPrinters() {
        WizardWindow.shared.show(at: .connect)
        WizardWindow.shared.model.startSearch()
    }

    @objc private func forgetPrinter() {
        Settings.printerID = nil
        Settings.printerName = nil
        StatusCenter.shared.update { $0.event = nil }
    }

    @objc private func cancelPrinting() { JobControl.cancel() }
    @objc private func openSetup() { WizardWindow.shared.show(at: Setup.isComplete ? .welcome : firstUnfinishedStep()) }
    @objc private func openAddStep() { WizardWindow.shared.show(at: .add) }

    private func firstUnfinishedStep() -> WizardStep {
        if Settings.printerID == nil { return .connect }
        if !Setup.printerInstalledCached { return .add }
        return .welcome
    }

    @objc private func runRecovery(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let r = Recovery(rawValue: raw) { handle(r) }
    }

    @objc private func openPrinters() { SystemSettings.openPrinters() }

    @objc private func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/munbyn-bt.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        }
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://github.com/valeriodon/munbyn-bt")!)
    }

    @objc private func toggleLogin() { Setup.setOpensAtLogin(!Setup.opensAtLogin) }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Prints to the MUNBYN ITPP130B over Bluetooth.\nUnofficial, not affiliated with MUNBYN.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationVersion: appVersion])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The menu bar glyph: a printer, with a cut-out badge for problems and the paper
/// version while printing. Template image, so it follows the menu bar's appearance.
func statusImage(printing: Bool, badge: String?) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    let baseName = printing ? "printer.filled.and.paper" : "printer"
    guard let base = (NSImage(systemSymbolName: baseName, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: "printer", accessibilityDescription: nil))?.withSymbolConfiguration(config) else {
        return NSImage()
    }
    guard let badge, let mark = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) else {
        base.isTemplate = true
        return base
    }
    let size = NSSize(width: base.size.width + 3, height: base.size.height + 2)
    let image = NSImage(size: size, flipped: false) { _ in
        base.draw(in: NSRect(x: 0, y: 2, width: base.size.width, height: base.size.height))
        let r = NSRect(x: size.width - mark.size.width, y: 0, width: mark.size.width, height: mark.size.height)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: r.insetBy(dx: -1.5, dy: -1.5))
            ctx.setBlendMode(.normal)
        }
        mark.draw(in: r)
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Demo states for the CI screenshots

private func applyDemoStatus(_ state: String) {
    Settings.printerName = "ITPP130B_4F2A"
    Settings.printerID = UUID()
    Setup.overrideInstalled(state != "notsetup")
    switch state {
    case "printing":
        StatusCenter.shared.update { $0.activity = .printing(index: 1, total: 2, fraction: 0.6) }
    case "error":
        StatusCenter.shared.update { $0.lastError = (Date(), UserError.printerNotFound); $0.errorSeen = false }
    case "ready":
        StatusCenter.shared.update { $0.lastJob = (Date(), "order-1234", 1) }
    default:
        break
    }
}

private func showDemoWizard(_ spec: String) {
    let model = WizardWindow.shared.model
    model.demo = true
    let devices = [NearbyDevice(id: UUID(), name: "ITPP130B_4F2A", rssi: -52, match: true),
                   NearbyDevice(id: UUID(), name: "ITPP130B_09C1", rssi: -78, match: true)]
    switch spec {
    case "connect": model.step = .connect
    case "connect-found": model.step = .connect; model.connect = .found(devices); model.selected = devices[0].id
    case "connect-failed":
        model.step = .connect
        let e = UserError.printerNotFound
        model.connect = .failed(e.title, e.message, e.recovery)
    case "labels": model.connect = .connected(devices[0].name); model.step = .labels
    case "add": model.connect = .connected(devices[0].name); model.step = .add
    case "test":
        model.connect = .connected(devices[0].name); model.add = .added; model.step = .test; model.test = .ask
        model.preparePreview()
    case "done": model.connect = .connected(devices[0].name); model.add = .added; model.step = .done
    case "walk":
        // Goes through every step like a person pressing Continue, logging how long each takes.
        logAllStepTimes = true
        model.connect = .connected(devices[0].name)
        model.add = .added
        for (i, step) in WizardStep.allCases.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i)) { model.go(step) }
        }
    default: model.step = .welcome
    }
    WizardWindow.shared.show()
}
