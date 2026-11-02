import Foundation
import CoreGraphics
import ImageIO

/// The ITPP130B print head is 108 mm wide at 203 dpi (8 dots per mm).
let dotsPerMM: CGFloat = 8
let maxWidthDots = 864
let pointsPerMM: CGFloat = 72 / 25.4

/// Grayscale image, row 0 at the top. After `binarize` every pixel is 0 (black) or 255 (white).
struct MonoBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

protocol PageSource {
    /// Upright page size in its own units (points for PDFs, pixels for images).
    var size: CGSize { get }
    /// Printer dots per unit at actual size.
    var dotsPerUnit: CGFloat { get }
    /// Draws the content into (0, 0, size), origin at the bottom left.
    func draw(in ctx: CGContext)
}

struct PDFPageSource: PageSource {
    let page: CGPDFPage
    let size: CGSize
    var dotsPerUnit: CGFloat { dotsPerMM / pointsPerMM }

    init(page: CGPDFPage) {
        self.page = page
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        size = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}

struct ImageSource: PageSource {
    let image: CGImage
    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var dotsPerUnit: CGFloat { 1 }

    func draw(in ctx: CGContext) {
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
    }
}

func loadPages(_ data: Data) throws -> [PageSource] {
    if data.prefix(1024).range(of: Data("%PDF".utf8)) != nil {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
            throw UserError.unreadable
        }
        guard doc.numberOfPages > 0 else { throw UserError.emptyPDF }
        return (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map(PDFPageSource.init)
    }
    if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
       let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        return [ImageSource(image: image)]
    }
    if data.starts(with: Data("%!".utf8)) {
        throw UserError.needsSetup
    }
    throw UserError.unreadable
}

func renderDocument(_ data: Data, opts: Options) throws -> [MonoBitmap] {
    try loadPages(data).map { renderPage($0, opts: opts) }
}

private func grayContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    return ctx
}

private func pixels(of ctx: CGContext) -> [UInt8] {
    let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
    let src = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 255, count: w * h)
    for y in 0..<h {
        for x in 0..<w { out[y * w + x] = src[y * stride + x] }
    }
    return out
}

/// Smallest rectangle containing everything that isn't white, in page units.
func contentBounds(_ src: PageSource) -> CGRect {
    let full = CGRect(origin: .zero, size: src.size)
    let scale = min(1600 / max(src.size.width, src.size.height), 4)
    let w = max(1, Int((src.size.width * scale).rounded(.up)))
    let h = max(1, Int((src.size.height * scale).rounded(.up)))
    let ctx = grayContext(width: w, height: h)
    ctx.scaleBy(x: scale, y: scale)
    src.draw(in: ctx)
    let px = pixels(of: ctx)
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w where px[y * w + x] < 235 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return full }
    let rect = CGRect(x: CGFloat(minX) / scale, y: CGFloat(h - maxY - 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    let pad = 1.5 / scale
    return rect.insetBy(dx: -pad, dy: -pad).intersection(full)
}

/// Puts a page on the label: crops white margins (if enabled), rotates it when
/// the orientation doesn't match and scales it to fit, keeping the aspect ratio.
func renderPage(_ src: PageSource, opts: Options) -> MonoBitmap {
    let pageMM = LabelSize(w: Double(src.size.width * src.dotsPerUnit / dotsPerMM),
                           h: Double(src.size.height * src.dotsPerUnit / dotsPerMM))
    let label: LabelSize
    if let fixed = opts.label {
        label = fixed
    } else if pageMM.w <= Double(maxWidthDots) / Double(dotsPerMM) + 2 {
        label = pageMM
    } else {
        label = opts.fallbackLabel
    }

    let content = opts.trim ? contentBounds(src) : CGRect(origin: .zero, size: src.size)
    let width = max(1, min(Int((label.w * Double(dotsPerMM)).rounded()), maxWidthDots))
    let height = max(1, Int((label.h * Double(dotsPerMM)).rounded()))

    var rotate = false
    if opts.autoRotate && width != height && abs(content.width - content.height) > 1 {
        rotate = (content.width > content.height) != (width > height)
    }
    let contentW = rotate ? content.height : content.width
    let contentH = rotate ? content.width : content.height
    let scale = min(CGFloat(width) / contentW, CGFloat(height) / contentH)

    let ctx = grayContext(width: width, height: height)
    ctx.translateBy(x: (CGFloat(width) - contentW * scale) / 2, y: (CGFloat(height) - contentH * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    if rotate {
        // Clockwise: labels placed sideways on an A4 sheet usually have their top on the left.
        ctx.translateBy(x: 0, y: content.width)
        ctx.rotate(by: -.pi / 2)
    }
    ctx.translateBy(x: -content.minX, y: -content.minY)
    ctx.clip(to: content)
    src.draw(in: ctx)

    var bitmap = MonoBitmap(width: width, height: height, pixels: pixels(of: ctx))
    binarize(&bitmap, threshold: opts.threshold, dither: opts.dither)
    return bitmap
}

func binarize(_ bm: inout MonoBitmap, threshold: Int, dither: Bool) {
    if !dither {
        for i in bm.pixels.indices { bm.pixels[i] = Int(bm.pixels[i]) > threshold ? 255 : 0 }
        return
    }
    // Floyd-Steinberg, for photos.
    let w = bm.width, h = bm.height
    var f = bm.pixels.map { Float($0) }
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            let old = f[i]
            let new: Float = old > 127 ? 255 : 0
            bm.pixels[i] = new == 255 ? 255 : 0
            let err = old - new
            if x + 1 < w { f[i + 1] += err * 7 / 16 }
            if y + 1 < h {
                if x > 0 { f[i + w - 1] += err * 3 / 16 }
                f[i + w] += err * 5 / 16
                if x + 1 < w { f[i + w + 1] += err / 16 }
            }
        }
    }
}

/// One TSPL job for one page, identical to what MUNBYN Editor sends.
func tsplJob(_ bm: MonoBitmap, opts: Options, copies: Int) -> Data {
    let rowBytes = (bm.width + 7) / 8
    // In the ITPP130B BITMAP command a 1 bit is white and a 0 bit is black.
    var bits = [UInt8](repeating: 0xFF, count: rowBytes * bm.height)
    for y in 0..<bm.height {
        let row = y * bm.width, out = y * rowBytes
        for x in 0..<bm.width where bm.pixels[row + x] == 0 {
            bits[out + (x >> 3)] &= ~(UInt8(0x80) >> UInt8(x & 7))
        }
    }
    let header = "SIZE \(rowBytes) mm,\(num(Double(bm.height) / 8)) mm\r\n"
        + "CLS\r\n"
        + "DIRECTION 0,0\r\n"
        + "GAP \(num(opts.gapMM)) mm,0 mm\r\n"
        + "SPEED \(opts.speed)\r\n"
        + "DENSITY \(opts.density)\r\n"
        + "REFERENCE 0,0\r\n"
        + "BITMAP \(opts.xOffset),0,\(rowBytes),\(bm.height),1,"
    var data = Data(header.utf8)
    data.append(contentsOf: bits)
    data.append(contentsOf: Array("\nPRINT 1,\(copies)\n".utf8))
    return data
}

func tsplJobs(_ bitmaps: [MonoBitmap], opts: Options) -> [Data] {
    if bitmaps.count == 1 { return [tsplJob(bitmaps[0], opts: opts, copies: opts.copies)] }
    var jobs: [Data] = []
    for _ in 0..<opts.copies {
        for b in bitmaps { jobs.append(tsplJob(b, opts: opts, copies: 1)) }
    }
    return jobs
}

func writePNG(_ bm: MonoBitmap, to path: String) throws {
    guard let provider = CGDataProvider(data: Data(bm.pixels) as CFData),
          let image = CGImage(width: bm.width, height: bm.height, bitsPerComponent: 8, bitsPerPixel: 8,
                              bytesPerRow: bm.width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { throw Failure("Cannot create \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("Cannot write \(path)") }
}

func writePreviews(_ bitmaps: [MonoBitmap], to path: String) throws {
    if bitmaps.count == 1 { return try writePNG(bitmaps[0], to: path) }
    let base = (path as NSString).deletingPathExtension
    for (i, b) in bitmaps.enumerated() { try writePNG(b, to: "\(base)-\(i + 1).png") }
}
