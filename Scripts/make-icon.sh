#!/bin/bash
# Renders a Notepad-style app icon and packs it into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
SRC="$WORK/icon.swift"
PNG="$WORK/icon-1024.png"

cat > "$SRC" <<'SWIFT'
import AppKit
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-rect background with a blue gradient.
let inset: CGFloat = size * 0.05
let bgRect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: size*0.22, yRadius: size*0.22)
NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.56, blue: 0.98, alpha: 1),
           ending:   NSColor(calibratedRed: 0.13, green: 0.34, blue: 0.80, alpha: 1))!
    .draw(in: bg, angle: -90)

// White page.
let px = size*0.27, pyTop = size*0.20, pyBot = size*0.18
let pageRect = NSRect(x: px, y: pyBot, width: size - 2*px, height: size - pyTop - pyBot)
let page = NSBezierPath(roundedRect: pageRect, xRadius: size*0.025, yRadius: size*0.025)
NSColor(calibratedWhite: 0, alpha: 0.12).setFill()
NSBezierPath(roundedRect: pageRect.offsetBy(dx: 0, dy: -size*0.012), xRadius: size*0.025, yRadius: size*0.025).fill()
NSColor.white.setFill(); page.fill()

// Blue header band.
let headerH = size*0.11
let header = NSRect(x: pageRect.minX, y: pageRect.maxY - headerH, width: pageRect.width, height: headerH)
NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.92, alpha: 1).setFill()
NSBezierPath(rect: header).fill()

// Text lines.
NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
let lineCount = 5
let area = NSRect(x: pageRect.minX + size*0.06, y: pageRect.minY + size*0.06,
                  width: pageRect.width - size*0.12, height: header.minY - pageRect.minY - size*0.10)
for i in 0..<lineCount {
    let y = area.maxY - CGFloat(i) * (area.height / CGFloat(lineCount - 1))
    let p = NSBezierPath()
    p.lineWidth = size*0.018
    p.lineCapStyle = .round
    let w: CGFloat = (i == lineCount - 1) ? area.width * 0.55 : area.width
    p.move(to: NSPoint(x: area.minX, y: y))
    p.line(to: NSPoint(x: area.minX + w, y: y))
    p.stroke()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc -O "$SRC" -o "$WORK/render" 2>/dev/null
"$WORK/render" "$PNG"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s        "$PNG" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp Resources/AppIcon.icns Sources/Notepad/AppIcon.icns   # bundled as a resource too
echo "Wrote Resources/AppIcon.icns (+ Sources/Notepad/AppIcon.icns)"
rm -rf "$WORK"
