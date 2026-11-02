import Foundation
import CoreGraphics
import CoreText

/// Test label: border, text in several sizes, barcode-like bars, a checkerboard
/// and a gray scale. With `onA4` it is placed sideways on an A4 sheet, the way
/// many carriers do it, to exercise cropping and rotation.
func makeTestPDF(label: LabelSize, onA4: Bool) -> Data {
    let lw = CGFloat(label.w) * pointsPerMM, lh = CGFloat(label.h) * pointsPerMM
    var media = onA4 ? CGRect(x: 0, y: 0, width: 595.28, height: 841.89) : CGRect(x: 0, y: 0, width: lw, height: lh)
    let out = NSMutableData()
    guard let consumer = CGDataConsumer(data: out as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return Data() }
    ctx.beginPDFPage(nil)
    ctx.saveGState()
    if onA4 {
        ctx.translateBy(x: 36 + lh, y: media.height - 36 - lw)
        ctx.rotate(by: .pi / 2)
    }
    drawTestLabel(ctx, width: lw, height: lh)
    ctx.restoreGState()
    ctx.endPDFPage()
    ctx.closePDF()
    return out as Data
}

private func drawText(_ text: String, size: CGFloat, bold: Bool = false, x: CGFloat, y: CGFloat, in ctx: CGContext) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

private func drawTestLabel(_ ctx: CGContext, width w: CGFloat, height h: CGFloat) {
    let m: CGFloat = 10
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.setStrokeColor(gray: 0, alpha: 1)
    ctx.setLineWidth(2.5)
    ctx.stroke(CGRect(x: m, y: m, width: w - 2 * m, height: h - 2 * m))

    // Upward arrow: shows at a glance whether the print is upside down.
    let ax = w / 2, top = h - m - 8
    ctx.move(to: CGPoint(x: ax, y: top))
    ctx.addLine(to: CGPoint(x: ax - 12, y: top - 16))
    ctx.addLine(to: CGPoint(x: ax + 12, y: top - 16))
    ctx.closePath()
    ctx.fillPath()

    var y = top - 46
    drawText("MUNBYN BT", size: min(30, w / 7), bold: true, x: m + 10, y: y, in: ctx)
    y -= 20
    drawText("Bluetooth test print", size: 11, x: m + 10, y: y, in: ctx)
    y -= 14
    let size = LabelSize(w: (Double(w / pointsPerMM) * 10).rounded() / 10, h: (Double(h / pointsPerMM) * 10).rounded() / 10)
    drawText("munbyn-bt \(appVersion) · \(sizeName(size)) mm", size: 8, x: m + 10, y: y, in: ctx)

    // Bars of different widths, like a barcode.
    let barTop = y - 12, barHeight = min(70, h * 0.2)
    var x = m + 10
    var seed: UInt32 = 7
    while x < w - m - 14 {
        seed = seed &* 1103515245 &+ 12345
        let bar = CGFloat((seed >> 16) % 4 + 1) * 0.9
        seed = seed &* 1103515245 &+ 12345
        let space = CGFloat((seed >> 16) % 3 + 1) * 0.9
        ctx.fill(CGRect(x: x, y: barTop - barHeight, width: bar, height: barHeight))
        x += bar + space
    }

    // Fine checkerboard and gray scale.
    let cell: CGFloat = 4
    let gridTop = barTop - barHeight - 12
    for row in 0..<8 {
        for col in 0..<8 where (row + col) % 2 == 0 {
            ctx.fill(CGRect(x: m + 10 + CGFloat(col) * cell, y: gridTop - CGFloat(row + 1) * cell, width: cell, height: cell))
        }
    }
    let steps = 8
    let stepWidth = (w - 2 * m - 70) / CGFloat(steps)
    for i in 0..<steps {
        ctx.setFillColor(gray: CGFloat(i) / CGFloat(steps - 1), alpha: 1)
        ctx.fill(CGRect(x: m + 54 + CGFloat(i) * stepWidth, y: gridTop - 8 * cell, width: stepWidth, height: 8 * cell))
    }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.stroke(CGRect(x: m + 54, y: gridTop - 8 * cell, width: stepWidth * CGFloat(steps), height: 8 * cell))

    var ty = gridTop - 8 * cell - 18
    for size in [14, 10, 8, 6] as [CGFloat] where ty > m + 12 {
        drawText("Text \(Int(size)) pt: ÀÉÎÕÜ àéîõü 0123456789", size: size, x: m + 10, y: ty, in: ctx)
        ty -= size + 6
    }
    drawText("BOTTOM", size: 8, bold: true, x: w / 2 - 18, y: m + 6, in: ctx)
}
