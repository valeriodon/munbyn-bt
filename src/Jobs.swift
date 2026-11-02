import Foundation
import CoreGraphics

/// Every print goes through here, one at a time.
let jobQueue = DispatchQueue(label: "munbyn-bt.jobs")

/// True when the app runs from the menu bar (notifications and UI available).
var isAppMode = false

/// What the app is doing right now.
enum Activity: Equatable {
    case idle
    case preparing(String)
    case connecting
    case printing(index: Int, total: Int, fraction: Double)
    case searching
    case checking
}

/// Status shown in the menu bar, the menu header and the setup assistant.
final class StatusCenter {
    static let shared = StatusCenter()

    struct Snapshot {
        var activity: Activity = .idle
        var lastJob: (date: Date, title: String, pages: Int)?
        var lastError: (date: Date, error: UserError)?
        /// The error badge on the menu bar icon goes away once the menu has been opened.
        var errorSeen = false
        var nearby: [NearbyDevice] = []
        /// A one-off message (for example "Connected to …"), shown until the next change.
        var event: String?

        var busy: Bool { activity != .idle }
        var hasUnseenError: Bool { lastError != nil && !errorSeen }
    }

    private let lock = NSLock()
    private var current = Snapshot()
    private var observers: [() -> Void] = []

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&current)
        let observers = self.observers
        lock.unlock()
        DispatchQueue.main.async { observers.forEach { $0() } }
    }

    /// Called on the main queue after every change.
    func observe(_ block: @escaping () -> Void) {
        lock.lock()
        observers.append(block)
        lock.unlock()
    }
}

/// Cancel flag for the job being printed.
enum JobControl {
    private static let lock = NSLock()
    private static var cancelled = false

    static var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    static func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    static func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}

/// The last job that failed, kept in memory so "Try Again" can resend it.
private var lastFailedJob: (data: Data, opts: Options, title: String)?
private let lastFailedLock = NSLock()

func retryLastFailedJob() {
    lastFailedLock.lock()
    let job = lastFailedJob
    lastFailedLock.unlock()
    guard let job else { return }
    jobQueue.async { runJobReporting(data: job.data, opts: job.opts, title: job.title) }
}

var hasFailedJob: Bool {
    lastFailedLock.lock(); defer { lastFailedLock.unlock() }
    return lastFailedJob != nil
}

private var printer: BLEPrinter?
private let printerLock = NSLock()

func sharedPrinter(_ opts: Options) -> BLEPrinter {
    printerLock.lock(); defer { printerLock.unlock() }
    if let p = printer { return p }
    let p = BLEPrinter(names: opts.names)
    printer = p
    return p
}

/// The shared printer only if it already exists, so reading it never triggers the Bluetooth prompt.
var existingPrinter: BLEPrinter? {
    printerLock.lock(); defer { printerLock.unlock() }
    return printer
}

/// A readable name for a job: the PDF's Title, the file name, or "label".
func documentTitle(_ data: Data, fallback: String = "label") -> String {
    if let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
       let info = doc.info {
        var value: CGPDFStringRef?
        if CGPDFDictionaryGetString(info, "Title", &value), let value,
           let title = CGPDFStringCopyTextString(value) as String?,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(title.prefix(40))
        }
    }
    return fallback
}

/// Sends ready-made TSPL jobs: to a file with --dry-run, otherwise over Bluetooth.
func deliver(_ jobs: [Data], opts: Options, progress: ((Double) -> Void)? = nil) throws {
    if let path = opts.dryRun {
        var all = Data()
        for j in jobs { all.append(j) }
        try all.write(to: URL(fileURLWithPath: path))
        say("Dry run: \(all.count) bytes of TSPL in \(path)")
        return
    }
    let ble = sharedPrinter(opts)
    StatusCenter.shared.update { $0.activity = .connecting }
    let info = try ble.connect(savedID: Settings.printerID)
    Settings.printerID = info.id
    Settings.printerName = info.name
    say("Connected to \(info.name)")
    defer { ble.disconnect() }
    let chunk = info.name.uppercased().contains("_LE") ? min(opts.chunk, 120) : opts.chunk
    for (i, job) in jobs.enumerated() {
        let started = Date()
        StatusCenter.shared.update { $0.activity = .printing(index: i + 1, total: jobs.count, fraction: 0) }
        try ble.send(job, chunk: chunk, pacingMs: opts.pacingMs, progress: { fraction in
            StatusCenter.shared.update { $0.activity = .printing(index: i + 1, total: jobs.count, fraction: fraction) }
            progress?((Double(i) + fraction) / Double(jobs.count))
        }, isCancelled: { JobControl.isCancelled })
        say("Page \(i + 1)/\(jobs.count): \(job.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if i < jobs.count - 1 { usleep(1_200_000) }
    }
}

/// Rasterizes a document, converts it to TSPL and prints it. Returns the number of pages.
@discardableResult
func runJob(data: Data, opts: Options, title: String, progress: ((Double) -> Void)? = nil) throws -> Int {
    JobControl.reset()
    StatusCenter.shared.update {
        $0.activity = .preparing(title)
        $0.event = nil
    }
    do {
        let bitmaps = try renderDocument(data, opts: opts)
        if let path = opts.preview { try writePreviews(bitmaps, to: path) }
        try deliver(tsplJobs(bitmaps, opts: opts), opts: opts, progress: progress)
        StatusCenter.shared.update {
            $0.activity = .idle
            $0.lastJob = (Date(), title, bitmaps.count)
            $0.lastError = nil
        }
        lastFailedLock.lock(); lastFailedJob = nil; lastFailedLock.unlock()
        return bitmaps.count
    } catch let error as UserError where error.title == UserError.cancelled.title {
        StatusCenter.shared.update {
            $0.activity = .idle
            $0.event = "Printing cancelled"
        }
        throw error
    } catch {
        let userError = (error as? UserError) ?? UserError.unreadable.with(details: "\(error)")
        lastFailedLock.lock(); lastFailedJob = (data, opts, title); lastFailedLock.unlock()
        StatusCenter.shared.update {
            $0.activity = .idle
            $0.lastError = (Date(), userError)
            $0.errorSeen = false
        }
        throw userError
    }
}

/// A job from CUPS or the menu: errors go to the log, a notification and VoiceOver.
func runJobReporting(data: Data, opts: Options, title: String) {
    do {
        let pages = try runJob(data: data, opts: opts, title: title)
        say("\(title): printed \(pages) page(s)")
        announce(pages == 1 ? "Label printed" : "\(pages) labels printed")
    } catch let error as UserError {
        say("\(title): \(error)")
        if error.title == UserError.cancelled.title { return }
        Notifier.shared.postFailure(error, jobTitle: title)
        announce("Label didn’t print. \(error.title)")
    } catch {
        say("\(title): \(error)")
    }
}
