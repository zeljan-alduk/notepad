import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An editable RGBA8 bitmap (premultiplied-last, row 0 = top row) decoded from
/// the document bytes. Pixel edits happen here, then get re-encoded and swapped
/// back into the document as one undoable step.
struct PixelBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // width * height * 4, RGBA row-major

    func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    mutating func set(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let i = (y * width + x) * 4
        pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = a
    }

    func makeCGImage() -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    static func rasterize(_ cg: CGImage) -> PixelBitmap? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? PixelBitmap(width: w, height: h, pixels: buf) : nil
    }
}

/// Maps pixels to file byte offsets for formats that store pixels raw. A pixel
/// in a compressed format (PNG, JPEG, …) has no byte address — its value is
/// spread across a compression stream — so this exists only where the mapping
/// is physically real (uncompressed BMP for now).
struct PixelAddresser {
    let dataOffset: Int
    let bytesPerPixel: Int
    let rowStride: Int
    let width: Int
    let height: Int
    let bottomUp: Bool

    func byteRange(x: Int, y: Int) -> Range<Int>? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let row = bottomUp ? height - 1 - y : y
        let start = dataOffset + row * rowStride + x * bytesPerPixel
        return start ..< start + bytesPerPixel
    }

    /// Inverse mapping: the pixel whose bytes contain `offset`, or nil for
    /// header/padding bytes.
    func pixel(atByte offset: Int) -> (x: Int, y: Int)? {
        let rel = offset - dataOffset
        guard rel >= 0 else { return nil }
        let row = rel / rowStride
        guard row < height else { return nil }
        let x = (rel % rowStride) / bytesPerPixel
        guard x < width else { return nil }   // row-alignment padding
        return (x, bottomUp ? height - 1 - row : row)
    }

    /// Parses an uncompressed 24/32-bit BMP header (pixels are BGR(A) rows,
    /// usually bottom-up, 4-byte-aligned stride).
    static func bmp(_ data: Data) -> PixelAddresser? {
        guard data.count > 54, data[0] == 0x42, data[1] == 0x4D else { return nil }
        func u32(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24 }
        func i32(_ i: Int) -> Int { Int(Int32(truncatingIfNeeded: UInt32(u32(i)))) }
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
        let dataOffset = u32(10)
        let width = i32(18), rawHeight = i32(22)
        let bpp = u16(28), compression = u32(30)
        // BI_RGB, or BI_BITFIELDS at 32bpp (still raw pixels, explicit masks).
        let rawPixels = compression == 0 || (compression == 3 && bpp == 32)
        guard rawPixels, bpp == 24 || bpp == 32, width > 0, rawHeight != 0 else { return nil }
        let height = abs(rawHeight)
        let stride = ((width * bpp + 31) / 32) * 4
        guard dataOffset > 0, dataOffset + stride * height <= data.count else { return nil }
        return PixelAddresser(dataOffset: dataOffset, bytesPerPixel: bpp / 8, rowStride: stride,
                              width: width, height: height, bottomUp: rawHeight > 0)
    }
}

/// Bounded, defensive image decoding for the hex editor's image panel.
///
/// The bytes being decoded are attacker-grade by definition — the user is hex
/// editing them — so decoding is hardened against hostile data:
/// - Input is an immutable `Data` *copy* (never a pointer into the live mmap),
///   so nothing dangles if the document closes or the file is swapped on save.
/// - Parsing goes through ImageIO (Apple's hardened, fuzzed parsers), never a
///   hand-rolled decoder.
/// - Header-claimed dimensions are checked *before* any pixel decode, and the
///   preview is refused past `maxSourcePixels` — a crafted header claiming
///   100,000×100,000 px can't trigger a multi-GB decompression bomb.
/// - Editable bitmaps are only built up to `maxEditablePixels`; bigger images
///   fall back to a thumbnail capped at `maxThumbnailPixelSize`, so allocation
///   is bounded no matter what the data claims.
/// - Decoding runs off the main thread and results are generation-checked, so
///   a slow or hostile file can neither hang the UI nor deliver stale pixels.
enum ImagePreview {
    /// Files bigger than this never get a preview (snapshot + decode cost).
    static let maxSourceBytes = 64 << 20
    /// Refuse to decode images whose header claims more pixels than this.
    static let maxSourcePixels = 80_000_000
    /// Full editable bitmaps are built only up to this many pixels (~64 MB RGBA).
    static let maxEditablePixels = 16_000_000
    /// Longest edge of the fallback (non-editable) preview.
    static let maxThumbnailPixelSize = 1024

    struct Result {
        let isImage: Bool
        let typeID: String?
        let bitmap: PixelBitmap?      // present when small enough to pixel-edit
        let fallbackImage: NSImage?   // thumbnail when the bitmap is withheld
        let addresser: PixelAddresser?// pixel → file-byte mapping, when real
        let info: String
    }

    static func decode(_ data: Data) -> Result {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, noCache),
              let type = CGImageSourceGetType(src) else {
            return Result(isImage: false, typeID: nil, bitmap: nil, fallbackImage: nil,
                          addresser: nil, info: "")
        }
        let addresser = (type as String == "com.microsoft.bmp") ? PixelAddresser.bmp(data) : nil

        var lines: [String] = []
        let typeID = type as String
        let typeName = UTType(typeID)?.localizedDescription ?? typeID
        lines.append("Format: \(typeName) (\(typeID))")
        let frames = CGImageSourceGetCount(src)
        if frames != 1 { lines.append("Frames: \(frames)") }
        lines.append("Data: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")

        guard frames > 0 else {
            return Result(isImage: true, typeID: typeID, bitmap: nil, fallbackImage: nil,
                          addresser: addresser,
                          info: (lines + ["", "No decodable frame."]).joined(separator: "\n"))
        }

        var claimedPixels = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            claimedPixels = w * h
            lines.append("Dimensions: \(w) × \(h) px")
            if let d = props[kCGImagePropertyDPIWidth] as? Double, d > 0 {
                lines.append("Resolution: \(Int(d)) DPI")
            }
            if let depth = props[kCGImagePropertyDepth] as? Int { lines.append("Bit depth: \(depth)") }
            if let model = props[kCGImagePropertyColorModel] as? String { lines.append("Color model: \(model)") }
            if let profile = props[kCGImagePropertyProfileName] as? String { lines.append("Color profile: \(profile)") }
            if let alpha = props[kCGImagePropertyHasAlpha] as? Bool { lines.append("Alpha: \(alpha ? "yes" : "no")") }
            if let orient = props[kCGImagePropertyOrientation] as? Int { lines.append("Orientation: \(orient)") }

            // Every remaining section (EXIF, TIFF, PNG, JFIF, GPS, IPTC, …).
            let summarized: Set<String> = [
                kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
                kCGImagePropertyDepth, kCGImagePropertyColorModel,
                kCGImagePropertyProfileName, kCGImagePropertyHasAlpha,
                kCGImagePropertyOrientation,
            ].reduce(into: []) { $0.insert($1 as String) }
            var detail: [String] = []
            flatten(props, prefix: "", skip: summarized, into: &detail)
            if !detail.isEmpty {
                lines.append("")
                lines.append(contentsOf: detail)
            }
        }

        guard claimedPixels <= maxSourcePixels else {
            lines.append("")
            lines.append("Preview skipped: header claims \(claimedPixels) px, over the \(maxSourcePixels) px safety cap.")
            return Result(isImage: true, typeID: typeID, bitmap: nil, fallbackImage: nil,
                          addresser: addresser, info: lines.joined(separator: "\n"))
        }

        // Small enough to edit: decode the real pixels once, into our buffer.
        if claimedPixels <= maxEditablePixels,
           let cg = CGImageSourceCreateImageAtIndex(src, 0, noCache),
           cg.width * cg.height <= maxEditablePixels,
           let bitmap = PixelBitmap.rasterize(cg) {
            return Result(isImage: true, typeID: typeID, bitmap: bitmap, fallbackImage: nil,
                          addresser: addresser, info: lines.joined(separator: "\n"))
        }

        // Too big to edit: bounded thumbnail, view-only.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailPixelSize,
        ]
        let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        lines.append("")
        lines.append(cg == nil ? "Preview unavailable: the data no longer decodes."
                               : "Pixel editing off: image exceeds \(maxEditablePixels) px cap.")
        return Result(isImage: true, typeID: typeID, bitmap: nil,
                      fallbackImage: cg.map { NSImage(cgImage: $0, size: .zero) },
                      addresser: addresser, info: lines.joined(separator: "\n"))
    }

    /// Re-encodes the edited bitmap in the original format (falling back to PNG
    /// for read-only formats like WebP).
    static func encode(_ bitmap: PixelBitmap, typeID: String?) -> Data? {
        guard let cg = bitmap.makeCGImage() else { return nil }
        for candidate in [typeID, UTType.png.identifier].compactMap({ $0 }) {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, candidate as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
            if CGImageDestinationFinalize(dest), out.length > 0 { return out as Data }
        }
        return nil
    }

    private static func flatten(_ dict: [CFString: Any], prefix: String,
                                skip: Set<String>, into lines: inout [String]) {
        let entries = dict.map { (key: $0.key as String, value: $0.value) }
            .filter { prefix.isEmpty ? !skip.contains($0.key) : true }
            .sorted { $0.key < $1.key }
        for (rawKey, value) in entries {
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let sub = value as? [CFString: Any] {
                flatten(sub, prefix: path, skip: skip, into: &lines)
            } else if let arr = value as? [Any] {
                lines.append("\(path): \(arr.map { "\($0)" }.joined(separator: ", "))")
            } else {
                lines.append("\(path): \(value)")
            }
        }
    }
}

/// Zoomable, pannable pixel canvas: nearest-neighbor rendering so individual
/// pixels become crisp squares at high zoom, a pixel grid past 8×, scroll to
/// pan, pinch or ⌥-scroll (and the panel's buttons) to zoom, click to select
/// a pixel for editing.
final class PixelCanvas: NSView {
    var onPixelSelected: ((Int, Int) -> Void)?
    var onViewChanged: (() -> Void)?

    private(set) var zoomScale: CGFloat = 1
    private var pan = CGPoint.zero        // view-space origin of image (0,0)
    private var cgCache: CGImage?
    private(set) var selected: (x: Int, y: Int)?

    var bitmap: PixelBitmap? {
        didSet {
            cgCache = bitmap?.makeCGImage()
            let sameSize = oldValue?.width == bitmap?.width && oldValue?.height == bitmap?.height
            if !sameSize { selected = nil; hasFitted = false; fit() }
            needsDisplay = true
        }
    }

    /// The first fit can only happen once the canvas has real bounds.
    private var hasFitted = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !hasFitted { fit() }
    }
    /// Shown when the image is too big to pixel-edit (view-only).
    var fallbackImage: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var imageSize: NSSize? {
        if let bitmap { return NSSize(width: bitmap.width, height: bitmap.height) }
        if let fallbackImage { return fallbackImage.size }
        return nil
    }

    /// Re-renders after in-place pixel mutations (bitmap didSet won't fire).
    func refreshPixels() {
        cgCache = bitmap?.makeCGImage()
        needsDisplay = true
    }

    func fit() {
        guard let size = imageSize, size.width > 0, size.height > 0,
              bounds.width > 8, bounds.height > 8 else { return }
        hasFitted = true
        zoomScale = min((bounds.width - 8) / size.width, (bounds.height - 8) / size.height)
        zoomScale = min(max(zoomScale, 0.02), 64)
        pan = CGPoint(x: (bounds.width - size.width * zoomScale) / 2,
                      y: (bounds.height - size.height * zoomScale) / 2)
        needsDisplay = true
        onViewChanged?()
    }

    func zoom(by factor: CGFloat) {
        zoomBy(factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Zooms to pixel level (if not already there), centers the pixel, and
    /// selects it — used when a byte in the hex view addresses a pixel.
    func reveal(x: Int, y: Int) {
        guard bitmap != nil else { return }
        if zoomScale < 8 { zoomScale = 16; hasFitted = true }
        pan = CGPoint(x: bounds.midX - (CGFloat(x) + 0.5) * zoomScale,
                      y: bounds.midY - (CGFloat(y) + 0.5) * zoomScale)
        selected = (x, y)
        needsDisplay = true
        onViewChanged?()
    }

    private func zoomBy(_ factor: CGFloat, at point: CGPoint) {
        let newZoom = min(max(zoomScale * factor, 0.02), 64)
        guard newZoom != zoomScale else { return }
        let imgPt = CGPoint(x: (point.x - pan.x) / zoomScale, y: (point.y - pan.y) / zoomScale)
        zoomScale = newZoom
        pan = CGPoint(x: point.x - imgPt.x * zoomScale, y: point.y - imgPt.y * zoomScale)
        clampPan()
        needsDisplay = true
        onViewChanged?()
    }

    private func clampPan() {
        guard let size = imageSize else { return }
        let w = size.width * zoomScale, h = size.height * zoomScale
        let margin: CGFloat = 24
        pan.x = min(max(pan.x, bounds.width - w - margin), bounds.width + margin - min(w, margin))
        pan.x = min(max(pan.x, -w + margin), bounds.width - margin)
        pan.y = min(max(pan.y, -h + margin), bounds.height - margin)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip their own drawing by default (macOS 14+): a
        // zoomed image or the pixel grid must not spill over the panel's other
        // controls, so clip explicitly.
        NSGraphicsContext.current!.cgContext.clip(to: bounds)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let size = imageSize else { return }
        let dest = NSRect(x: pan.x, y: pan.y,
                          width: size.width * zoomScale, height: size.height * zoomScale)

        NSColor.textBackgroundColor.setFill()
        dest.fill()

        if let cg = cgCache {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.interpolationQuality = zoomScale >= 1 ? .none : .medium
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: dest.size))
            ctx.restoreGState()
        } else if let img = fallbackImage {
            img.draw(in: dest)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: dest.insetBy(dx: -0.5, dy: -0.5)).stroke()

        // Pixel grid once pixels are big enough to address individually.
        if bitmap != nil, zoomScale >= 8 {
            NSColor.textColor.withAlphaComponent(0.12).setStroke()
            let grid = NSBezierPath()
            var x = dest.minX
            while x <= dest.maxX + 0.5 {
                grid.move(to: NSPoint(x: x, y: max(dest.minY, 0)))
                grid.line(to: NSPoint(x: x, y: min(dest.maxY, bounds.height)))
                x += zoomScale
            }
            var y = dest.minY
            while y <= dest.maxY + 0.5 {
                grid.move(to: NSPoint(x: max(dest.minX, 0), y: y))
                grid.line(to: NSPoint(x: min(dest.maxX, bounds.width), y: y))
                y += zoomScale
            }
            grid.lineWidth = 1
            grid.stroke()
        }

        if let sel = selected {
            let r = NSRect(x: pan.x + CGFloat(sel.x) * zoomScale,
                           y: pan.y + CGFloat(sel.y) * zoomScale,
                           width: zoomScale, height: zoomScale)
                .insetBy(dx: -1, dy: -1)
            NSColor.white.setStroke()
            let outer = NSBezierPath(rect: r); outer.lineWidth = 3; outer.stroke()
            NSColor.systemRed.setStroke()
            let inner = NSBezierPath(rect: r); inner.lineWidth = 1; inner.stroke()
        }
    }

    // MARK: - Interaction

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            zoomBy(exp(event.scrollingDeltaY * 0.02), at: convert(event.locationInWindow, from: nil))
            return
        }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        clampPan()
        needsDisplay = true
        onViewChanged?()
    }

    override func magnify(with event: NSEvent) {
        zoomBy(1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    private var downPoint = CGPoint.zero
    private var lastDrag = CGPoint.zero
    private var moved = false

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        lastDrag = downPoint
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - downPoint.x) + abs(p.y - downPoint.y) > 3 { moved = true }
        pan.x += p.x - lastDrag.x
        pan.y += p.y - lastDrag.y
        lastDrag = p
        clampPan()
        needsDisplay = true
        onViewChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        guard !moved, let bitmap else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = Int(((p.x - pan.x) / zoomScale).rounded(.down))
        let y = Int(((p.y - pan.y) / zoomScale).rounded(.down))
        guard x >= 0, x < bitmap.width, y >= 0, y < bitmap.height else { return }
        selected = (x, y)
        needsDisplay = true
        onPixelSelected?(x, y)
    }
}

/// Right-hand panel of the hex window for image files: a zoomable pixel canvas
/// on top, a per-pixel RGBA editor in the middle, and the full decoded metadata
/// below. Sits outside the hex scroll area, so it stays visible while the bytes
/// scroll; pixel edits are re-encoded and applied back to the document bytes.
final class ImageInspector: NSView {
    let canvas = PixelCanvas()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let fitButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "")

    private let pixelLabel = NSTextField(labelWithString: "Click a pixel to edit it")
    private var channelFields: [NSTextField] = []   // R, G, B, A
    private let swatch = NSView()
    private let applyButton = NSButton()
    private let discardButton = NSButton()

    private let infoScroll = NSScrollView()
    private let infoText = NSTextView()

    /// Current decoded state.
    private var typeID: String?
    private var addresser: PixelAddresser?
    private var pristinePixels: [UInt8]?    // set on first pixel edit
    private var editedPixelCount = 0
    private var hasPendingEdits: Bool { pristinePixels != nil }

    /// Called with the edited bitmap + original UTI; the owner re-encodes it
    /// and swaps the bytes into the document.
    var onApplyPixels: ((PixelBitmap, String?) -> Void)?
    /// A pixel was clicked; the range is its file-byte address when the format
    /// stores pixels raw (nil for compressed formats).
    var onPixelPicked: ((_ x: Int, _ y: Int, _ byteRange: Range<Int>?) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(canvas)
        canvas.onPixelSelected = { [weak self] x, y in self?.showPixel(x: x, y: y, notify: true) }
        canvas.onViewChanged = { [weak self] in self?.updateZoomLabel() }

        for (button, title, action) in [
            (zoomOutButton, "−", #selector(zoomOutPressed)),
            (zoomInButton, "+", #selector(zoomInPressed)),
            (fitButton, "Fit", #selector(fitPressed)),
        ] {
            button.title = title
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = AppFonts.ui(11)
            button.target = self
            button.action = action
            addSubview(button)
        }
        zoomLabel.font = AppFonts.ui(11)
        zoomLabel.textColor = .secondaryLabelColor
        addSubview(zoomLabel)

        pixelLabel.font = AppFonts.ui(11)
        pixelLabel.textColor = .secondaryLabelColor
        pixelLabel.lineBreakMode = .byTruncatingTail
        addSubview(pixelLabel)

        for _ in 0..<4 {
            let field = NSTextField(string: "")
            field.font = AppFonts.editor(11)
            field.controlSize = .small
            field.alignment = .center
            field.target = self
            field.action = #selector(channelEdited(_:))
            field.isEnabled = false
            addSubview(field)
            channelFields.append(field)
        }
        swatch.wantsLayer = true
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.borderWidth = 1
        addSubview(swatch)

        applyButton.title = "Apply to Bytes"
        applyButton.bezelStyle = .texturedRounded
        applyButton.controlSize = .small
        applyButton.font = AppFonts.ui(11)
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        applyButton.isEnabled = false
        addSubview(applyButton)

        discardButton.title = "Discard"
        discardButton.bezelStyle = .texturedRounded
        discardButton.controlSize = .small
        discardButton.font = AppFonts.ui(11)
        discardButton.target = self
        discardButton.action = #selector(discardPressed)
        discardButton.isEnabled = false
        addSubview(discardButton)

        infoText.isEditable = false
        infoText.isSelectable = true
        // Darker well than the panel chrome, so the metadata reads as content.
        infoText.drawsBackground = true
        infoText.backgroundColor = .underPageBackgroundColor
        infoText.font = AppFonts.editor(11)
        infoText.textColor = .labelColor
        infoText.textContainerInset = NSSize(width: 6, height: 6)
        infoText.isVerticallyResizable = true
        infoText.isHorizontallyResizable = false
        infoText.autoresizingMask = [.width]
        infoText.textContainer?.widthTracksTextView = true
        infoScroll.documentView = infoText
        infoScroll.hasVerticalScroller = true
        infoScroll.drawsBackground = true
        infoScroll.backgroundColor = .underPageBackgroundColor
        infoScroll.borderType = .noBorder
        addSubview(infoScroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Feeding decoded results in

    func set(result: ImagePreview.Result) {
        infoText.string = result.info.isEmpty
            ? "Preview unavailable: the data no longer decodes as an image."
            : result.info
        typeID = result.typeID ?? typeID
        addresser = result.addresser
        // Never clobber the user's unapplied pixel edits with a re-decode
        // (metadata above still refreshes).
        guard !hasPendingEdits else { return }
        canvas.fallbackImage = result.fallbackImage
        canvas.bitmap = result.bitmap
        let editable = result.bitmap != nil
        pixelLabel.stringValue = editable ? "Click a pixel to edit it"
                                          : "Pixel editing unavailable"
        if !editable { setFieldsEnabled(false) }
        updateZoomLabel()
    }

    private func setFieldsEnabled(_ on: Bool) {
        for field in channelFields {
            field.isEnabled = on
            if !on { field.stringValue = "" }
        }
        if !on { swatch.layer?.backgroundColor = nil }
    }

    // MARK: - Pixel editing

    private func showPixel(x: Int, y: Int, notify: Bool) {
        guard let px = canvas.bitmap?.rgba(x: x, y: y) else { return }
        let byteRange = addresser?.byteRange(x: x, y: y)
        pixelLabel.stringValue = byteRange == nil
            ? "Pixel (\(x), \(y)) RGBA — no byte address (compressed)"
            : "Pixel (\(x), \(y)) RGBA"
        let values = [px.r, px.g, px.b, px.a]
        for (field, v) in zip(channelFields, values) { field.stringValue = "\(v)" }
        setSwatch(px)
        for field in channelFields { field.isEnabled = true }
        if notify { onPixelPicked?(x, y, byteRange) }
    }

    /// Reverse sync: the hex caret landed on a byte that addresses a pixel —
    /// zoom the canvas to it and select it. Silent (no onPixelPicked), so the
    /// two directions can't feed back into each other.
    func revealPixel(forByte offset: Int) {
        guard let addresser, canvas.bitmap != nil,
              let (x, y) = addresser.pixel(atByte: offset) else { return }
        if let sel = canvas.selected, sel == (x, y) { return }
        canvas.reveal(x: x, y: y)
        showPixel(x: x, y: y, notify: false)
    }

    private func setSwatch(_ px: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        swatch.layer?.backgroundColor = CGColor(
            red: CGFloat(px.r) / 255, green: CGFloat(px.g) / 255,
            blue: CGFloat(px.b) / 255, alpha: CGFloat(px.a) / 255)
    }

    @objc private func channelEdited(_ sender: NSTextField) {
        guard let sel = canvas.selected, var bitmap = canvas.bitmap,
              let old = bitmap.rgba(x: sel.x, y: sel.y) else { return }
        var values = [old.r, old.g, old.b, old.a]
        for (i, field) in channelFields.enumerated() {
            let clamped = UInt8(min(max(Int(field.stringValue) ?? Int(values[i]), 0), 255))
            values[i] = clamped
            field.stringValue = "\(clamped)"
        }
        guard values != [old.r, old.g, old.b, old.a] else { return }
        if pristinePixels == nil { pristinePixels = bitmap.pixels }
        bitmap.set(x: sel.x, y: sel.y, r: values[0], g: values[1], b: values[2], a: values[3])
        editedPixelCount += 1
        canvas.bitmap = bitmap
        canvas.refreshPixels()
        setSwatch((values[0], values[1], values[2], values[3]))
        applyButton.isEnabled = true
        discardButton.isEnabled = true
        pixelLabel.stringValue = "Pixel (\(sel.x), \(sel.y)) RGBA — \(editedPixelCount) edit(s) pending"
    }

    @objc private func applyPressed(_ sender: Any?) {
        guard let bitmap = canvas.bitmap else { return }
        pristinePixels = nil
        editedPixelCount = 0
        applyButton.isEnabled = false
        discardButton.isEnabled = false
        pixelLabel.stringValue = "Re-encoding…"
        onApplyPixels?(bitmap, typeID)
    }

    @objc private func discardPressed(_ sender: Any?) {
        if let pristine = pristinePixels, var bitmap = canvas.bitmap {
            bitmap.pixels = pristine
            canvas.bitmap = bitmap
            canvas.refreshPixels()
        }
        pristinePixels = nil
        editedPixelCount = 0
        applyButton.isEnabled = false
        discardButton.isEnabled = false
        if let sel = canvas.selected { showPixel(x: sel.x, y: sel.y, notify: false) }
        else { pixelLabel.stringValue = "Click a pixel to edit it" }
    }

    // MARK: - Zoom controls

    @objc private func zoomInPressed(_ sender: Any?) { canvas.zoom(by: 2) }
    @objc private func zoomOutPressed(_ sender: Any?) { canvas.zoom(by: 0.5) }
    @objc private func fitPressed(_ sender: Any?) { canvas.fit() }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((canvas.zoomScale * 100).rounded()))%"
    }

    // MARK: - Layout / drawing

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let toolbarH: CGFloat = 24
        var x = pad
        for button in [zoomOutButton, zoomInButton, fitButton] {
            button.sizeToFit()
            let w = max(button.frame.width, 26)
            button.frame = NSRect(x: x, y: 4, width: w, height: toolbarH - 4)
            x += w + 4
        }
        zoomLabel.sizeToFit()
        zoomLabel.frame.origin = NSPoint(x: x + 2, y: (toolbarH - zoomLabel.frame.height) / 2 + 2)

        let canvasH = max(140, bounds.height * 0.42)
        canvas.frame = NSRect(x: 1, y: toolbarH + 4, width: bounds.width - 1, height: canvasH)

        var y = toolbarH + 4 + canvasH + 6
        pixelLabel.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 16)
        y += 20
        let fieldW: CGFloat = 44
        var fx = pad
        for field in channelFields {
            field.frame = NSRect(x: fx, y: y, width: fieldW, height: 20)
            fx += fieldW + 4
        }
        swatch.frame = NSRect(x: fx, y: y, width: 28, height: 20)
        y += 26
        applyButton.sizeToFit()
        applyButton.frame = NSRect(x: pad, y: y, width: max(applyButton.frame.width, 100), height: 20)
        discardButton.sizeToFit()
        discardButton.frame = NSRect(x: applyButton.frame.maxX + 6, y: y,
                                     width: max(discardButton.frame.width, 64), height: 20)
        y += 28

        infoScroll.frame = NSRect(x: 1, y: y, width: bounds.width - 1,
                                  height: max(0, bounds.height - y))
        infoText.textContainer?.containerSize = NSSize(
            width: infoScroll.contentSize.width, height: .greatestFiniteMagnitude)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}
