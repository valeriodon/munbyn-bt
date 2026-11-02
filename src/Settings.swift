import Foundation

struct LabelSize: Equatable {
    var w: Double  // mm
    var h: Double  // mm
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    /// Fixed label size; nil = use the size of the incoming page.
    var label: LabelSize? = nil
    /// Size used when the page is wider than the print head (A4, Letter...).
    var fallbackLabel = LabelSize(w: 100, h: 150)
    var trim = true
    var autoRotate = true
    var density = 8
    var speed = 4
    var copies = 1
    var threshold = 155
    var dither = false
    var gapMM = 2.0
    var xOffset = -8
    var names = ["ITPP130B"]
    var chunk = 180
    var pacingMs = 8.0
    var dryRun: String? = nil
    var dryRunDir: String? = nil
    var preview: String? = nil
    var port: UInt16 = 9100
    var headless = false
    var showMenu = false
    var demoWizard: String? = nil
    var demoStatus: String? = nil
    var demoDark = false
    var a4 = false

    static func fromSettings() -> Options {
        var o = Options()
        o.fallbackLabel = Settings.label
        o.trim = Settings.trim
        o.density = Settings.density
        o.speed = Settings.speed
        o.dither = Settings.dither
        return o
    }
}

/// 4 x 6 in where people measure in inches, 100 x 150 mm elsewhere.
var defaultLabel: LabelSize {
    Locale.current.measurementSystem == .us ? LabelSize(w: 101.6, h: 152.4) : LabelSize(w: 100, h: 150)
}

/// Preferences shared by the menu bar app and the command line.
enum Settings {
    static let store = UserDefaults(suiteName: "com.valeriodon.munbyn-bt.settings") ?? .standard

    static var label: LabelSize {
        get { parseSize(store.string(forKey: "label") ?? "") ?? defaultLabel }
        set { store.set(sizeName(newValue), forKey: "label") }
    }
    static var density: Int {
        get { store.object(forKey: "density") as? Int ?? 8 }
        set { store.set(newValue, forKey: "density") }
    }
    static var speed: Int {
        get { store.object(forKey: "speed") as? Int ?? 4 }
        set { store.set(newValue, forKey: "speed") }
    }
    static var trim: Bool {
        get { store.object(forKey: "trim") as? Bool ?? true }
        set { store.set(newValue, forKey: "trim") }
    }
    static var dither: Bool {
        get { store.bool(forKey: "dither") }
        set { store.set(newValue, forKey: "dither") }
    }
    static var printerID: UUID? {
        get { store.string(forKey: "printerID").flatMap { UUID(uuidString: $0) } }
        set { store.set(newValue?.uuidString, forKey: "printerID") }
    }
    /// The setup assistant was finished (or closed with Set Up Later).
    static var setupFinished: Bool {
        get { store.bool(forKey: "setupFinished") }
        set { store.set(newValue, forKey: "setupFinished") }
    }
    static var setupDismissed: Bool {
        get { store.bool(forKey: "setupDismissed") }
        set { store.set(newValue, forKey: "setupDismissed") }
    }
    static var printerName: String? {
        get { store.string(forKey: "printerName") }
        set { store.set(newValue, forKey: "printerName") }
    }
}

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func say(_ text: String) {
    FileHandle.standardError.write(Data("[\(logFormatter.string(from: Date()))] \(text)\n".utf8))
}

func fail(_ text: String) -> Never {
    say("Error: \(text)")
    exit(1)
}

func num(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
}

func sizeName(_ s: LabelSize) -> String { "\(num(s.w))x\(num(s.h))" }

/// "100x150", "100x150mm" or "4x6in".
func parseSize(_ text: String) -> LabelSize? {
    var t = text.lowercased().replacingOccurrences(of: " ", with: "")
    var factor = 1.0
    if t.hasSuffix("in") { factor = 25.4; t.removeLast(2) } else if t.hasSuffix("mm") { t.removeLast(2) }
    let parts = t.split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
    return LabelSize(w: w * factor, h: h * factor)
}
