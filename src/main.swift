import Foundation

// munbyn-bt: print to the MUNBYN ITPP130B label printer over Bluetooth LE from a Mac.
//
// The protocol is the one MUNBYN Editor (editor.munbyn.com) uses: TSPL commands
// written without response to the printer's ISSC "transparent UART" service.
// The app lives in the menu bar, receives jobs from CUPS on 127.0.0.1:9100
// (the "MUNBYN ITPP130B" queue uses the socket:// backend) and forwards them over Bluetooth.

let appVersion = "1.0.0"

let helpText = """
munbyn-bt \(appVersion) · print to the MUNBYN ITPP130B over Bluetooth

  munbyn-bt                  start the menu bar app (done automatically at login)
  munbyn-bt print FILE       print a PDF or an image
  munbyn-bt test             print a test label
  munbyn-bt selftest         make the printer print its self-test page
  munbyn-bt scan             list nearby Bluetooth devices

Print options:
  --label 100x150    label size in mm (or 4x6in)
  --density N        print density 1-15
  --speed N          print speed 1-6
  --copies N         number of copies
  --no-trim          don't crop white margins
  --dither           dithering, for photos
  --dry-run FILE     write the TSPL commands to a file instead of printing
  --preview FILE     save a PNG preview of what would be printed
"""

setvbuf(stdout, nil, _IOLBF, 0)

var argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let command = argv.first.map { $0.hasPrefix("--") ? "app" : $0 } ?? "app"
if command != "app" { argv.removeFirst() }

var opts = Options.fromSettings()
var positional: [String] = []
var argIndex = 0

func value(_ flag: String) -> String {
    argIndex += 1
    guard argIndex < argv.count else { fail("missing value for \(flag)") }
    return argv[argIndex]
}

func intIn(_ text: String, _ range: ClosedRange<Int>, _ flag: String) -> Int {
    guard let v = Int(text), range.contains(v) else { fail("\(flag) must be between \(range.lowerBound) and \(range.upperBound)") }
    return v
}

while argIndex < argv.count {
    let a = argv[argIndex]
    switch a {
    case "--label":
        guard let s = parseSize(value(a)) else { fail("invalid size, for example: --label 100x150") }
        opts.label = s
    case "--trim": opts.trim = true
    case "--no-trim": opts.trim = false
    case "--no-rotate": opts.autoRotate = false
    case "--density": opts.density = intIn(value(a), 1...15, a)
    case "--speed": opts.speed = intIn(value(a), 1...6, a)
    case "--copies": opts.copies = intIn(value(a), 1...999, a)
    case "--threshold": opts.threshold = intIn(value(a), 1...254, a)
    case "--dither": opts.dither = true
    case "--gap": opts.gapMM = Double(value(a)) ?? opts.gapMM
    case "--x-offset": opts.xOffset = Int(value(a)) ?? opts.xOffset
    case "--name": opts.names = value(a).split(separator: ",").map(String.init)
    case "--dry-run": opts.dryRun = value(a)
    case "--dry-run-dir": opts.dryRunDir = value(a)
    case "--preview": opts.preview = value(a)
    case "--port": opts.port = UInt16(value(a)) ?? opts.port
    case "--headless": opts.headless = true
    case "--show-menu": opts.showMenu = true
    case "--demo-wizard": opts.demoWizard = value(a)
    case "--demo-status": opts.demoStatus = value(a)
    case "--demo-dark": opts.demoDark = true
    case "--a4": opts.a4 = true
    case "-h", "--help": print(helpText); exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)") }
        positional.append(a)
    }
    argIndex += 1
}

switch command {
case "app", "serve":
    runApp(opts)

case "print":
    guard let path = positional.first else { fail("usage: munbyn-bt print FILE [options]") }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pages = try runJob(data: data, opts: opts, title: (path as NSString).lastPathComponent)
        say("Done: \(pages) page(s)")
    } catch {
        fail("\(error)")
    }

case "test":
    do {
        let data = makeTestPDF(label: opts.label ?? opts.fallbackLabel, onA4: false, settings: testLabelFooter(opts))
        _ = try runJob(data: data, opts: opts, title: "test label")
    } catch {
        fail("\(error)")
    }

case "selftest":
    do { try deliver([Data("REFERENCE 0,0\nSELFTEST\n".utf8)], opts: opts) } catch { fail("\(error)") }

case "scan":
    do {
        let found = try sharedPrinter(opts).scanAll(seconds: 10)
        if found.isEmpty { say("No Bluetooth LE devices found") }
        for d in found { print("\(d.match ? "→" : " ") \(d.name)  \(d.rssi) dBm  \(d.id.uuidString)") }
    } catch {
        fail("\(error)")
    }

case "make-test-pdf":
    guard let path = positional.first else { fail("usage: munbyn-bt make-test-pdf FILE [--label 100x150] [--a4]") }
    do { try makeTestPDF(label: opts.label ?? opts.fallbackLabel, onA4: opts.a4).write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }

case "login-item":
    Setup.setOpensAtLogin(positional.first != "off")

case "ppd":
    print(ppd(defaultLabel: opts.label ?? opts.fallbackLabel), terminator: "")

case "version", "--version":
    print(appVersion)

case "help":
    print(helpText)

default:
    print(helpText)
    exit(2)
}
