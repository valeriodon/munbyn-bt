import Foundation

/// Every print goes through here, one at a time.
let jobQueue = DispatchQueue(label: "munbyn-bt.jobs")

/// Status shown in the menu bar.
final class StatusCenter {
    static let shared = StatusCenter()

    struct Snapshot {
        var state = "Ready"
        var lastJob = "none"
        var busy = false
        var error = false
        var nearby: [NearbyDevice] = []
    }

    private let lock = NSLock()
    private var current = Snapshot()
    var onChange: (() -> Void)?

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&current)
        lock.unlock()
        onChange?()
    }
}

private var printer: BLEPrinter?

func sharedPrinter(_ opts: Options) -> BLEPrinter {
    if let p = printer { return p }
    let p = BLEPrinter(names: opts.names)
    printer = p
    return p
}

/// Sends ready-made TSPL jobs: to a file with --dry-run, otherwise over Bluetooth.
func deliver(_ jobs: [Data], opts: Options) throws {
    if let path = opts.dryRun {
        var all = Data()
        for j in jobs { all.append(j) }
        try all.write(to: URL(fileURLWithPath: path))
        say("Dry run: \(all.count) bytes of TSPL in \(path)")
        return
    }
    let ble = sharedPrinter(opts)
    StatusCenter.shared.update { $0.state = "Connecting to the printer…" }
    let info = try ble.connect(savedID: Settings.printerID)
    Settings.printerID = info.id
    Settings.printerName = info.name
    say("Connected to \(info.name)")
    defer { ble.disconnect() }
    let chunk = info.name.uppercased().contains("_LE") ? min(opts.chunk, 120) : opts.chunk
    for (i, job) in jobs.enumerated() {
        let started = Date()
        let label = jobs.count > 1 ? "Printing \(i + 1) of \(jobs.count)" : "Printing"
        StatusCenter.shared.update { $0.state = label }
        try ble.send(job, chunk: chunk, pacingMs: opts.pacingMs) { fraction in
            StatusCenter.shared.update { $0.state = "\(label) · \(Int(fraction * 100))%" }
        }
        say("Page \(i + 1)/\(jobs.count): \(job.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if i < jobs.count - 1 { usleep(1_200_000) }
    }
}

/// Rasterizes a document, converts it to TSPL and prints it. Returns the number of pages.
@discardableResult
func runJob(data: Data, opts: Options, title: String) throws -> Int {
    StatusCenter.shared.update {
        $0.busy = true
        $0.error = false
        $0.state = "Preparing \(title)…"
    }
    do {
        let bitmaps = try renderDocument(data, opts: opts)
        if let path = opts.preview { try writePreviews(bitmaps, to: path) }
        try deliver(tsplJobs(bitmaps, opts: opts), opts: opts)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        StatusCenter.shared.update {
            $0.busy = false
            $0.state = "Ready"
            $0.lastJob = "\(time) · \(title) · \(bitmaps.count) p."
        }
        return bitmaps.count
    } catch {
        StatusCenter.shared.update {
            $0.busy = false
            $0.error = true
            $0.state = "Error: \(error)"
        }
        throw error
    }
}

/// A job from CUPS or the menu: errors go to the log and to a notification.
func runJobReporting(data: Data, opts: Options, title: String) {
    do {
        let pages = try runJob(data: data, opts: opts, title: title)
        say("\(title): printed \(pages) page(s)")
    } catch {
        say("\(title): \(error)")
        notify("Print failed", "\(error)")
    }
}
