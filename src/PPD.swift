import Foundation

struct Media {
    let key: String
    let name: String
    let w: Double  // PostScript points
    let h: Double

    var mm: LabelSize { LabelSize(w: w * 25.4 / 72, h: h * 25.4 / 72) }

    static func millimeters(_ w: Double, _ h: Double, _ note: String = "") -> Media {
        let pw = w * 72 / 25.4, ph = h * 72 / 25.4
        return Media(key: "w\(Int(pw.rounded()))h\(Int(ph.rounded()))", name: "\(num(w))x\(num(h)) mm\(note)", w: pw, h: ph)
    }

    static func inches(_ w: Double, _ h: Double) -> Media {
        Media(key: "w\(Int((w * 72).rounded()))h\(Int((h * 72).rounded()))", name: "\(num(w))x\(num(h)) in", w: w * 72, h: h * 72)
    }
}

/// Label sizes offered in the menu and in the print dialog.
let labelMedia: [Media] = [
    .millimeters(100, 150), .inches(4, 6), .millimeters(105, 148, " (A6)"), .millimeters(100, 100), .inches(4, 4),
    .millimeters(100, 70), .millimeters(100, 50), .inches(3, 2), .millimeters(60, 40), .millimeters(50, 30),
    .inches(2.25, 1.25), .millimeters(40, 30),
]

/// PPD for the CUPS queue: passes the PDF through unchanged (application/vnd.cups-pdf)
/// to the socket:// backend; munbyn-bt does the conversion.
func ppd(defaultLabel: LabelSize) -> String {
    var sizes = labelMedia
    var defaultMedia = Media.millimeters(defaultLabel.w, defaultLabel.h)
    if let known = sizes.first(where: { abs($0.w - defaultMedia.w) < 1 && abs($0.h - defaultMedia.h) < 1 }) {
        defaultMedia = known
    } else {
        sizes.insert(defaultMedia, at: 0)
    }
    sizes += [Media(key: "A4", name: "A4 (crop and fit)", w: 595.28, h: 841.89),
              Media(key: "Letter", name: "Letter (crop and fit)", w: 612, h: 792)]
    func p(_ v: Double) -> String { String(format: "%.2f", v) }

    var s = """
    *PPD-Adobe: "4.3"
    *FormatVersion: "4.3"
    *FileVersion: "\(appVersion)"
    *LanguageVersion: English
    *LanguageEncoding: ISOLatin1
    *PCFileName: "MUNBYNBT.PPD"
    *Manufacturer: "MUNBYN"
    *Product: "(ITPP130B)"
    *ModelName: "MUNBYN ITPP130B Bluetooth"
    *ShortNickName: "MUNBYN ITPP130B Bluetooth"
    *NickName: "MUNBYN ITPP130B Bluetooth (munbyn-bt)"
    *PSVersion: "(3010.000) 0"
    *LanguageLevel: "3"
    *ColorDevice: False
    *DefaultColorSpace: Gray
    *FileSystem: False
    *Throughput: "1"
    *LandscapeOrientation: Plus90
    *TTRasterizer: Type42
    *cupsVersion: 2.2
    *cupsManualCopies: True
    *cupsFilter: "application/vnd.cups-pdf 0 -"
    *DefaultResolution: 203dpi
    *Resolution 203dpi/203 dpi: ""

    """
    for (ui, label) in [("PageSize", "Media Size"), ("PageRegion", "Page Region")] {
        s += "*OpenUI *\(ui)/\(label): PickOne\n*OrderDependency: 10 AnySetup *\(ui)\n*Default\(ui): \(defaultMedia.key)\n"
        for m in sizes {
            s += "*\(ui) \(m.key)/\(m.name): \"<</PageSize[\(p(m.w)) \(p(m.h))]/ImagingBBox null>>setpagedevice\"\n"
        }
        s += "*CloseUI: *\(ui)\n"
    }
    s += "*DefaultImageableArea: \(defaultMedia.key)\n"
    for m in sizes { s += "*ImageableArea \(m.key)/\(m.name): \"0 0 \(p(m.w)) \(p(m.h))\"\n" }
    s += "*DefaultPaperDimension: \(defaultMedia.key)\n"
    for m in sizes { s += "*PaperDimension \(m.key)/\(m.name): \"\(p(m.w)) \(p(m.h))\"\n" }
    return s
}
