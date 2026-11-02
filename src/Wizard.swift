import AppKit
import SwiftUI
import CoreBluetooth
import QuartzCore

// The setup assistant: connect the printer, choose the labels, add it to the Mac,
// print a test label. It opens by itself on first launch and from the menu later.

enum WizardStep: Int, CaseIterable {
    case welcome, connect, labels, add, test, done

    /// Shown as "Step N of 4"; welcome and done aren't counted.
    var number: Int? { (1...4).contains(rawValue) ? rawValue : nil }
}

final class WizardModel: ObservableObject {
    enum ConnectState: Equatable {
        case idle
        case searching
        case found([NearbyDevice])
        case connecting(String)
        case connected(String)
        case failed(String, String, Recovery)  // title, message, recovery
    }
    enum AddState: Equatable { case idle, waiting, added, cancelled, failed(String) }
    enum TestState: Equatable { case idle, printing(Double), ask, nothing, failed(String, String), adjusted(Int) }

    @Published var step: WizardStep = .welcome
    @Published var connect: ConnectState = .idle
    @Published var selected: UUID?
    @Published var label: LabelSize = Settings.label
    @Published var add: AddState = .idle
    @Published var test: TestState = .idle
    @Published var openAtLogin = true
    @Published var notifyFailures = true
    /// The test label preview, drawn in the background before the test step needs it.
    @Published var preview: NSImage?

    var demo = false
    var onFinish: (() -> Void)?
    private var searchCancelled = false

    var opts: Options {
        var o = Options.fromSettings()
        o.names = appOptions.names
        return o
    }

    func go(_ step: WizardStep) {
        let started = CACurrentMediaTime()
        self.step = step
        // Runs after the new step is laid out: logs how long the change took, to spot slow steps.
        DispatchQueue.main.async {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 150 || logAllStepTimes { say("Setup assistant: \(step) took \(ms) ms to appear") }
        }
        if step.rawValue >= WizardStep.labels.rawValue { preparePreview() }
        switch step {
        case .add where !demo && add == .idle:
            Setup.refreshPrinterInstalled { [weak self] installed in
                if installed, self?.add == .idle { self?.add = .added }
            }
        case .connect where connect == .idle:
            if let name = Settings.printerName, Settings.printerID != nil { connect = .connected(name) }
        default:
            break
        }
    }

    func next() {
        if let n = WizardStep(rawValue: step.rawValue + 1) { go(n) }
    }

    func back() {
        if let n = WizardStep(rawValue: step.rawValue - 1) { go(n) }
    }

    // MARK: Connect

    func startSearch() {
        guard !demo else { return }
        searchCancelled = false
        connect = .searching
        announce("Searching for your printer. Make sure it’s on.")
        let o = opts
        jobQueue.async { [weak self] in
            guard let self else { return }
            let ble = sharedPrinter(o)
            ble.onStateChange = { [weak self] state in self?.bluetoothChanged(state) }
            do {
                var firstMatch: Date?
                let list = try ble.scan(seconds: 25, onUpdate: { list in
                    let printers = list.filter(\.match)
                    if !printers.isEmpty, firstMatch == nil { firstMatch = Date() }
                    DispatchQueue.main.async { if !printers.isEmpty { self.showFound(printers) } }
                }, stopWhen: { _ in
                    // Keep listening a moment after the first printer, in case there are two.
                    firstMatch.map { Date().timeIntervalSince($0) > 2 } ?? false
                }, isCancelled: { self.searchCancelled })
                let printers = list.filter(\.match)
                DispatchQueue.main.async {
                    if self.searchCancelled { self.connect = .idle; return }
                    if printers.isEmpty {
                        let paired = ble.pairedInSettings()
                        let e = paired.map { UserError.pairedInSettings($0) } ?? UserError.printerNotFound
                        self.connect = .failed(e.title, e.message, e.recovery)
                        announce("\(e.title). \(e.message)")
                    } else {
                        self.showFound(printers)
                        announce(printers.count == 1 ? "Found \(printers[0].name). Press Use This Printer." : "Found \(printers.count) printers. Choose one from the list.")
                    }
                }
            } catch {
                let e = (error as? UserError) ?? UserError.bluetoothNotReady
                DispatchQueue.main.async {
                    self.connect = .failed(e.title, e.message, e.recovery)
                    announce("\(e.title). \(e.message)")
                }
            }
        }
    }

    private func showFound(_ printers: [NearbyDevice]) {
        if case .found(let current) = connect, current == printers { return }
        connect = .found(printers)
        if selected == nil || !printers.contains(where: { $0.id == selected }) { selected = printers.first?.id }
    }

    func stopSearch() { searchCancelled = true }

    func useSelected() {
        guard case .found(let printers) = connect, let device = printers.first(where: { $0.id == selected }) ?? printers.first else { return }
        connect = .connecting(device.name)
        let o = opts
        jobQueue.async { [weak self] in
            do {
                let ble = sharedPrinter(o)
                let info = try ble.connect(savedID: device.id)
                ble.disconnect()
                Settings.printerID = info.id
                Settings.printerName = device.name
                DispatchQueue.main.async {
                    self?.connect = .connected(device.name)
                    announce("Connected to \(device.name).")
                }
            } catch {
                let e = (error as? UserError) ?? UserError.noResponse
                DispatchQueue.main.async {
                    self?.connect = .failed(e.title, e.message, e.recovery)
                    announce("\(e.title). \(e.message)")
                }
            }
        }
    }

    /// Bluetooth was turned on or allowed while the assistant waits: try again by itself.
    func bluetoothChanged(_ state: CBManagerState) {
        guard step == .connect, case .failed(_, _, let recovery) = connect,
              recovery == .openBluetoothSettings || recovery == .openPrivacySettings, state == .poweredOn else { return }
        announce("Bluetooth is ready.")
        startSearch()
    }

    // MARK: Labels

    func saveLabel() {
        let changed = Settings.label != label
        Settings.label = label
        Setup.syncDefaultPageSize()
        if changed { preparePreview(force: true) }
    }

    // MARK: Add

    func addPrinter() {
        guard !demo else { return }
        add = .waiting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Setup.installPrinter()
                DispatchQueue.main.async {
                    self?.add = .added
                    announce("Printer added to your Mac.")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } catch is Setup.CancelledByUser {
                DispatchQueue.main.async { self?.add = .cancelled; NSApp.activate(ignoringOtherApps: true) }
            } catch {
                let details = (error as? UserError)?.details ?? "\(error)"
                DispatchQueue.main.async { self?.add = .failed(details); NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }

    // MARK: Test

    func printTest() {
        guard !demo else { return }
        test = .printing(0)
        let o = opts
        let data = makeTestPDF(label: o.fallbackLabel, onA4: false, settings: testLabelFooter(o))
        jobQueue.async { [weak self] in
            do {
                try runJob(data: data, opts: o, title: "test label") { fraction in
                    DispatchQueue.main.async { if case .printing = self?.test { self?.test = .printing(fraction) } }
                }
                DispatchQueue.main.async {
                    self?.test = .ask
                    announce("Test label sent. How does it look?")
                }
            } catch {
                let e = (error as? UserError) ?? UserError.noResponse
                DispatchQueue.main.async {
                    self?.test = .failed(e.title, e.message)
                    announce("\(e.title). \(e.message)")
                }
            }
        }
    }

    func adjustDarkness(by delta: Int) {
        Settings.density = min(15, max(1, Settings.density + delta))
        test = .adjusted(Settings.density)
        preparePreview(force: true)  // the footer lists the darkness
    }

    func preparePreview(force: Bool = false) {
        guard preview == nil || force else { return }
        let o = opts
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = renderTestPreview(o)
            DispatchQueue.main.async { self?.preview = image }
        }
    }

    // MARK: Done

    func finish() {
        if !demo {
            Setup.setOpensAtLogin(openAtLogin)
            if notifyFailures { Notifier.shared.requestAuthorization() }
            Settings.setupFinished = true
        }
        onFinish?()
    }
}

/// Set by the CI walk-through, which logs every step change.
var logAllStepTimes = false

/// The text printed at the bottom of the test label.
func testLabelFooter(_ o: Options) -> [String] {
    ["Darkness \(o.density) · Speed \(o.speed) · Crop and Fit \(o.trim ? "on" : "off")",
     "Print from any app: ⌘P › \(Setup.queueTitle)"]
}

// MARK: - Window

final class WizardWindow: NSObject, NSWindowDelegate {
    static let shared = WizardWindow()
    let model = WizardModel()
    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    func show(at step: WizardStep? = nil) {
        if let step { model.go(step) }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WizardView(model: model)))
            w.title = "MunbynBT Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 560, height: 470))
            w.center()
            window = w
            model.onFinish = { [weak self] in self?.window?.close() }
        }
        // While the assistant is open it appears in the Dock and in ⌘-Tab, so it can't get lost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Switching to a regular app takes effect on the next turn of the run loop:
        // activate again then, so the window is really in front and takes the first click.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.stopSearch()
        if !Settings.setupFinished { Settings.setupDismissed = true }
        window = nil
        NSApp.setActivationPolicy(.accessory)
        StatusCenter.shared.update { _ in }
    }
}

// MARK: - Views

/// The warm paper tone of the app icon, with a dark counterpart.
let stripBackground = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.17, green: 0.16, blue: 0.15, alpha: 1)
        : NSColor(srgbRed: 0.965, green: 0.945, blue: 0.91, alpha: 1)
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model)
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: stripBackground))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let n = model.step.number {
                    Text("Step \(n) of 4")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 470)
        .onChange(of: model.step) { _ in headingFocused = true }
    }

    private var title: String {
        switch model.step {
        case .welcome: return "Print labels from any app"
        case .connect:
            switch model.connect {
            case .searching: return "Looking for your printer…"
            case .found(let p): return p.count == 1 ? "Found your printer" : "Which printer is yours?"
            case .connecting: return "Connecting…"
            case .connected: return "Your printer is connected"
            case .failed(let t, _, _): return t
            case .idle: return "Turn on your printer"
            }
        case .labels: return "Which labels are in your printer?"
        case .add:
            switch model.add {
            case .added: return "Added to your Mac"
            case .cancelled: return "The printer wasn’t added"
            case .failed: return "The printer couldn’t be added"
            default: return "Add the printer to your Mac"
            }
        case .test:
            switch model.test {
            case .ask, .adjusted: return "How does it look?"
            case .nothing: return "Nothing came out?"
            case .failed(let t, _): return t
            case .printing: return "Printing a test label…"
            case .idle: return "Print a test label"
            }
        case .done: return "You’re all set"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .connect: ConnectStep(model: model)
        case .labels: LabelsStep(model: model)
        case .add: AddStep(model: model)
        case .test: TestStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch model.step {
            case .welcome:
                Spacer()
                Button("Set Up Later") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Get Started") { model.next() }
                    .keyboardShortcut(.defaultAction)
            case .connect:
                Button("Back") { model.stopSearch(); model.back() }
                Spacer()
                connectButtons
            case .labels:
                Button("Back") { model.back() }
                Spacer()
                Button("Continue") { model.saveLabel(); model.next() }
                    .keyboardShortcut(.defaultAction)
            case .add:
                Button("Back") { model.back() }
                    .disabled(model.add == .waiting)
                Spacer()
                addButtons
            case .test:
                Button("Back") { model.back() }
                    .disabled(isPrinting)
                Spacer()
                testButtons
            case .done:
                Spacer()
                Button("Done") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var isPrinting: Bool { if case .printing = model.test { return true } else { return false } }

    @ViewBuilder private var connectButtons: some View {
        switch model.connect {
        case .idle:
            Button("Find My Printer") { model.startSearch() }.keyboardShortcut(.defaultAction)
        case .searching:
            Button("Stop") { model.stopSearch() }.keyboardShortcut(.cancelAction)
        case .found:
            Button("Search Again") { model.startSearch() }
            Button("Use This Printer") { model.useSelected() }.keyboardShortcut(.defaultAction)
        case .connecting:
            Button("Use This Printer") {}.disabled(true)
        case .connected:
            Button("Use Another Printer") { model.startSearch() }
            Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
        case .failed(_, _, let recovery):
            if let title = recovery.buttonTitle, recovery == .openBluetoothSettings || recovery == .openPrivacySettings {
                Button(title) { SystemSettings.open(recovery) }
            }
            Button("Try Again") { model.startSearch() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var addButtons: some View {
        switch model.add {
        case .added:
            Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
        case .waiting:
            Button("Add Printer…") {}.disabled(true)
        case .idle:
            Button("Add Printer…") { model.addPrinter() }.keyboardShortcut(.defaultAction)
        case .cancelled, .failed:
            Button("Skip") { model.next() }
            Button("Try Again") { model.addPrinter() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var testButtons: some View {
        switch model.test {
        case .idle:
            Button("Skip") { model.next() }
            Button("Print Test Label") { model.printTest() }.keyboardShortcut(.defaultAction)
        case .printing:
            Button("Print Test Label") {}.disabled(true)
        case .ask:
            Button("Nothing Came Out") { model.test = .nothing }
            Button("Too Light") { model.adjustDarkness(by: 2) }
            Button("Too Dark") { model.adjustDarkness(by: -2) }
            Button("Looks Good") { model.next() }.keyboardShortcut(.defaultAction)
        case .adjusted:
            Button("Skip") { model.next() }
            Button("Print Again") { model.printTest() }.keyboardShortcut(.defaultAction)
        case .nothing, .failed:
            Button("Skip") { model.next() }
            Button("Print Again") { model.printTest() }.keyboardShortcut(.defaultAction)
        }
    }
}

/// Printer, Bluetooth, Mac: three nodes that fill in as setup progresses.
/// Every node pairs a symbol with words, never color alone.
struct StatusStrip: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            node(symbol: "printer", title: "Printer", state: printerState)
            link
            node(symbol: "laptopcomputer", title: "Mac", state: macState)
        }
        .accessibilityElement(children: .combine)
    }

    private enum NodeState { case pending(String), working(String), done(String), problem(String) }

    private var printerState: NodeState {
        switch model.connect {
        case .idle: return Settings.printerName.map { .done($0) } ?? .pending("Turn it on")
        case .searching: return .working("Looking…")
        case .found(let p): return .working(p.count == 1 ? p[0].name : "\(p.count) found")
        case .connecting(let n): return .working(n)
        case .connected(let n): return .done(n)
        case .failed: return .problem("Not connected")
        }
    }

    private var macState: NodeState {
        switch model.add {
        case .added: return .done("In Printers & Scanners")
        case .waiting: return .working("Adding…")
        case .failed, .cancelled: return .problem("Not added")
        case .idle: return .pending("Not added yet")
        }
    }

    private var linkConnected: Bool { if case .connected = model.connect { return true } else { return false } }

    private var link: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                line
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(linkConnected ? Color.accentColor : .secondary)
                line
            }
            .frame(height: 40)
            Text(linkConnected ? "Connected" : "Bluetooth")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 170)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(linkConnected ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(height: linkConnected ? 2 : 1)
    }

    private func node(symbol: String, title: String, state: NodeState) -> some View {
        let (badge, text, tint): (String?, String, Color) = {
            switch state {
            case .pending(let t): return (nil, t, .secondary)
            case .working(let t): return ("ellipsis.circle.fill", t, .secondary)
            case .done(let t): return ("checkmark.circle.fill", t, .green)
            case .problem(let t): return ("exclamationmark.triangle.fill", t, .orange)
            }
        }()
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 52, height: 40)
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 14))
                        .foregroundStyle(tint)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                }
            }
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(text)")
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Hint: View {
    let symbol: String
    let text: String
    var body: some View {
        Label {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("MunbynBT turns your MUNBYN ITPP130B into a regular Mac printer. Setup takes about a minute.")
            VStack(alignment: .leading, spacing: 8) {
                Hint(symbol: "1.circle", text: "Connect your printer over Bluetooth")
                Hint(symbol: "2.circle", text: "Choose the labels you use")
                Hint(symbol: "3.circle", text: "Add it to your Mac")
                Hint(symbol: "4.circle", text: "Print a test label")
            }
        }
    }
}

struct ConnectStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.connect {
            case .idle:
                Paragraph("Switch it on and keep it within a few meters of your Mac. You don’t need to pair it in Bluetooth settings.")
                Hint(symbol: "info.circle", text: "macOS will ask whether MunbynBT may use Bluetooth. Click Allow.")
            case .searching:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Paragraph("This usually takes a few seconds.")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Searching for printers")
            case .found(let printers):
                if printers.count > 1 {
                    Paragraph("Not sure? Pick the closest one. You’ll print a test label in a moment.")
                }
                List(printers, id: \.id, selection: $model.selected) { p in
                    HStack {
                        Image(systemName: "printer")
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(p == printers.first && printers.count > 1 ? "\(p.signal) · closest" : p.signal)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .combine)
                }
                .frame(height: min(CGFloat(printers.count) * 36 + 12, 130))
                .listStyle(.bordered(alternatesRowBackgrounds: false))
            case .connecting(let name):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Paragraph("Connecting to \(name)…")
                }
            case .connected(let name):
                Paragraph("\(name) is ready. MunbynBT will connect to it whenever you print.")
            case .failed(let title, let message, let recovery):
                // "Printer not found" is all checklist; other errors say what happened first.
                Paragraph(title == UserError.printerNotFound.title ? "Check these, then try again:" : message)
                if title == UserError.printerNotFound.title {
                    VStack(alignment: .leading, spacing: 6) {
                        Hint(symbol: "power", text: "Is it on? The light should be lit.")
                        Hint(symbol: "dot.radiowaves.left.and.right", text: "Is it within a few meters of your Mac?")
                        Hint(symbol: "iphone", text: "Is the MUNBYN app open on your phone? Close it.")
                        Hint(symbol: "gearshape", text: "Paired in System Settings › Bluetooth? Remove it there.")
                    }
                }
            }
        }
    }
}

struct LabelsStep: View {
    @ObservedObject var model: WizardModel

    private var main: [Media] { Array(labelMedia.prefix(3)) }
    private var others: [Media] { Array(labelMedia.dropFirst(3)) }
    private func isCurrent(_ m: Media) -> Bool { abs(m.mm.w - model.label.w) < 0.5 && abs(m.mm.h - model.label.h) < 0.5 }
    private var currentKey: String { (labelMedia.first(where: isCurrent) ?? labelMedia[0]).key }
    private var isOther: Bool { !main.contains { $0.key == currentKey } }

    private func pick(_ key: String) {
        if key == "other" { model.label = others[0].mm }
        else if let m = labelMedia.first(where: { $0.key == key }) { model.label = m.mm }
    }

    private func hint(_ m: Media) -> String {
        switch m.key {
        case "w283h425": return "most shipping labels in Europe"
        case "w288h432": return "most shipping labels in the US"
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Shipping labels that arrive on an A4 or Letter page are cropped and fitted to this size.")
            Picker("Labels", selection: Binding(get: { isOther ? "other" : currentKey }, set: pick)) {
                ForEach(main, id: \.key) { m in
                    Text(hint(m).isEmpty ? displayName(m) : "\(displayName(m))  ·  \(hint(m))").tag(m.key)
                }
                Text("Another size").tag("other")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if isOther {
                Picker("Size", selection: Binding(get: { currentKey }, set: pick)) {
                    ForEach(others, id: \.key) { m in Text(displayName(m)).tag(m.key) }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
                .padding(.leading, 20)
            }
        }
    }
}

/// "100 × 150 mm" for the interface ("x" stays in the PPD, which is Latin-1).
func displayName(_ m: Media) -> String {
    m.name.replacingOccurrences(of: "x", with: " × ")
}

struct AddStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.add {
            case .idle, .waiting:
                Paragraph("This puts “\(Setup.queueTitle)” in the print dialog of every app. macOS will ask for your password once. MunbynBT never sees it.")
                if model.add == .waiting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Paragraph("Waiting for your password…")
                    }
                }
            case .added:
                Paragraph("You’ll find “\(Setup.queueTitle)” in every print dialog.")
            case .cancelled:
                Paragraph("Adding a printer needs your Mac password. You can also do it later from the MunbynBT menu.")
            case .failed(let details):
                Paragraph(UserError.printerNotAdded.message)
                DisclosureGroup("Details") {
                    Text(details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                .font(.system(size: 12))
            }
        }
    }
}

struct TestStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.test {
            case .idle:
                Paragraph("You’ll get one label to check that it’s sharp and the right way up. It also lists your settings.")
            case .printing(let fraction):
                ProgressView(value: fraction)
                    .accessibilityLabel("Printing")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
                Paragraph("Keep the printer on until the label is out.")
            case .ask:
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Paragraph("Compare it with this preview. The arrow should point up, the bars should be crisp and the smallest text readable.")
                        Hint(symbol: "circle.lefthalf.filled", text: "Pale or patchy? Choose Too Light. Smudged or bleeding? Choose Too Dark.")
                    }
                    TestPreview(image: model.preview)
                }
            case .adjusted(let darkness):
                Paragraph("Darkness set to \(darkness). Print again to check.")
            case .nothing:
                VStack(alignment: .leading, spacing: 6) {
                    Hint(symbol: "rectangle.portrait.on.rectangle.portrait", text: "Are labels loaded, and is the cover closed?")
                    Hint(symbol: "power", text: "Is the printer on, with the light lit?")
                    Hint(symbol: "doc.text", text: "Still nothing? Print the printer’s own self-test from the MunbynBT menu.")
                }
            case .failed(_, let message):
                Paragraph(message)
            }
        }
    }
}

/// What the test label should look like, rendered by the same code that prints it.
func renderTestPreview(_ o: Options) -> NSImage? {
    guard let bm = try? renderDocument(makeTestPDF(label: o.fallbackLabel, onA4: false, settings: testLabelFooter(o)), opts: o).first,
          let provider = CGDataProvider(data: Data(bm.pixels) as CFData),
          let cg = CGImage(width: bm.width, height: bm.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bm.width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: bm.width, height: bm.height))
}

struct TestPreview: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white
            }
        }
        .frame(width: 114, height: 170)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .accessibilityLabel("Preview of the test label")
    }
}

struct DoneStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Print from any app with ⌘P and choose “\(Setup.queueTitle)”.")
            Hint(symbol: "doc.richtext", text: "Label on an A4 or Letter page? Pick A4 or Letter as the paper size and it’s fitted to your label.")
            Hint(symbol: "menubar.arrow.up.rectangle", text: "Settings and status are in the menu bar, under the printer icon.")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Open MunbynBT at login (needed to print)", isOn: $model.openAtLogin)
                Toggle("Tell me when a label can’t print", isOn: $model.notifyFailures)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        }
    }
}
