import Foundation

/// Differential fuzz test: apply identical random edits to the PieceTable and to
/// a trivially-correct `[UInt8]` reference, then assert the content and every
/// line-geometry query agree. Run via `FlashPad --selftest`.
enum SelfTest {
    // Deterministic LCG so failures reproduce.
    private struct RNG {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    static func run() -> Never {
        var failures = 0

        // Build an original file with mixed LF / CRLF lines.
        let seed = "alpha\nbeta line\r\ngamma\n\nlast unterminated tail"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-selftest-\(getpid()).txt")
        try! Data(seed.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let file = MappedFile(url: tmp) else { fatalError("mmap failed") }
        let index = LineIndex(file: file)
        index.buildSynchronously()
        let pt = PieceTable(original: file, index: index)
        var ref = Array(seed.utf8)

        func check(_ label: String) {
            // Content
            let got = pt.string(in: 0..<pt.byteCount)
            let want = String(decoding: ref, as: UTF8.self)
            if got != want {
                failures += 1
                print("FAIL [\(label)] content mismatch\n  got:  \(debug(got))\n  want: \(debug(want))")
                return
            }
            // Line count
            let wantLines = ref.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + 1
            if pt.lineCount != wantLines {
                failures += 1
                print("FAIL [\(label)] lineCount \(pt.lineCount) != \(wantLines)")
                return
            }
            // Every line's start/end
            for line in 0..<wantLines {
                let (rs, re) = refLineBounds(ref, line)
                if pt.lineStart(line) != rs || pt.lineEnd(line) != re {
                    failures += 1
                    print("FAIL [\(label)] line \(line): got [\(pt.lineStart(line)),\(pt.lineEnd(line))) want [\(rs),\(re))")
                    return
                }
            }
        }

        check("initial")

        var rng = RNG(state: 0x1234_5678)
        let alphabet = Array("xy z\n01\r\n".utf8)
        for step in 0..<4000 {
            if pt.byteCount > 0, rng.next(2) == 0 {
                // delete
                let a = rng.next(pt.byteCount)
                let b = min(pt.byteCount, a + 1 + rng.next(6))
                pt.delete(a..<b)
                ref.removeSubrange(a..<b)
            } else {
                // insert
                let at = rng.next(pt.byteCount + 1)
                let len = 1 + rng.next(5)
                var s = [UInt8]()
                for _ in 0..<len { s.append(alphabet[rng.next(alphabet.count)]) }
                pt.insert(String(decoding: s, as: UTF8.self), at: at)
                ref.insert(contentsOf: s, at: at)
            }
            if step % 200 == 0 { check("step \(step)") }
            if failures > 0 { break }
        }
        check("final")

        // --- search correctness vs naive reference ---
        func refFind(_ needle: [UInt8], _ from: Int) -> Int? {
            guard !needle.isEmpty, from + needle.count <= ref.count else { return nil }
            var i = from
            while i + needle.count <= ref.count {
                if Array(ref[i..<i + needle.count]) == needle { return i }
                i += 1
            }
            return nil
        }
        let needles: [[UInt8]] = [Array("z".utf8), Array("xy".utf8),
                                  Array("\n".utf8), Array("01".utf8), Array("zz0".utf8)]
        for nd in needles {
            var from = 0
            while from <= ref.count {
                let got = pt.nextMatch(of: nd, from: from, caseSensitive: true)?.lowerBound
                let want = refFind(nd, from)
                if got != want {
                    failures += 1
                    print("FAIL [search] needle \(nd) from \(from): got \(String(describing: got)) want \(String(describing: want))")
                    break
                }
                guard let w = want else { break }
                from = w + 1
            }
        }

        // --- hex overlay document: overwrite edits vs reference, save, undo ---
        var hexSeed = [UInt8]()
        for _ in 0..<4096 { hexSeed.append(UInt8(rng.next(256))) }
        let hexTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-selftest-\(getpid()).bin")
        try! Data(hexSeed).write(to: hexTmp)
        defer { try? FileManager.default.removeItem(at: hexTmp) }

        if let hexFile = MappedFile(url: hexTmp) {
            let hdoc = HexDocument(file: hexFile, url: hexTmp)
            var hexRef = hexSeed
            for _ in 0..<2000 {
                switch rng.next(3) {
                case 0:   // overwrite (clipped at EOF)
                    guard !hexRef.isEmpty else { continue }
                    let at = rng.next(hexRef.count)
                    var bytes = [UInt8]()
                    for _ in 0..<(1 + rng.next(8)) { bytes.append(UInt8(rng.next(256))) }
                    hdoc.setBytes(bytes, at: at)
                    for (i, b) in bytes.enumerated() where at + i < hexRef.count { hexRef[at + i] = b }
                case 1:   // insert
                    let at = rng.next(hexRef.count + 1)
                    var bytes = [UInt8]()
                    for _ in 0..<(1 + rng.next(8)) { bytes.append(UInt8(rng.next(256))) }
                    hdoc.insert(bytes, at: at)
                    hexRef.insert(contentsOf: bytes, at: at)
                default:  // delete
                    guard !hexRef.isEmpty else { continue }
                    let a = rng.next(hexRef.count)
                    let b = min(hexRef.count, a + 1 + rng.next(8))
                    hdoc.delete(a..<b)
                    hexRef.removeSubrange(a..<b)
                }
            }
            if hdoc.byteCount != hexRef.count {
                failures += 1
                print("FAIL [hex] byteCount \(hdoc.byteCount) != \(hexRef.count)")
            }
            for i in 0..<min(hdoc.byteCount, hexRef.count) where hdoc.byte(at: i) != hexRef[i] {
                failures += 1
                print("FAIL [hex] byte \(i): got \(hdoc.byte(at: i)) want \(hexRef[i])")
                break
            }

            let hexOut = FileManager.default.temporaryDirectory
                .appendingPathComponent("hex-selftest-out-\(getpid()).bin")
            defer { try? FileManager.default.removeItem(at: hexOut) }
            do {
                try hdoc.save(to: hexOut)
                if Array(try Data(contentsOf: hexOut)) != hexRef {
                    failures += 1; print("FAIL [hex] save round-trip mismatch")
                }
                if hdoc.isModified { failures += 1; print("FAIL [hex] still modified after save") }
            } catch {
                failures += 1; print("FAIL [hex] save threw \(error)")
            }

            while hdoc.undoManager.canUndo { hdoc.undoManager.undo() }
            for i in 0..<hexSeed.count where hdoc.byte(at: i) != hexSeed[i] {
                failures += 1
                print("FAIL [hex] undo-all mismatch at \(i)")
                break
            }

            // --- pixel editing: bitmap → PNG → bitmap round-trip, then an
            // undoable whole-content swap (the Apply-to-Bytes path) ---
            var bmp = PixelBitmap(width: 4, height: 3, pixels: [UInt8](repeating: 255, count: 48))
            bmp.set(x: 1, y: 2, r: 10, g: 20, b: 30, a: 255)
            if let png = ImagePreview.encode(bmp, typeID: "public.png") {
                let decoded = ImagePreview.decode(png)
                if let back = decoded.bitmap, back.width == 4, back.height == 3,
                   let px = back.rgba(x: 1, y: 2), px == (10, 20, 30, 255) {
                    // round-trip OK
                } else {
                    failures += 1
                    print("FAIL [pixel] PNG round-trip lost the edited pixel")
                }
                do {
                    try hdoc.replaceContents(with: png)
                    var swapped = hdoc.byteCount == png.count
                    if swapped {
                        for (i, b) in png.enumerated() where hdoc.byte(at: i) != b { swapped = false; break }
                    }
                    if !swapped { failures += 1; print("FAIL [pixel] replaceContents content mismatch") }
                    if !hdoc.isModified { failures += 1; print("FAIL [pixel] replaceContents not marked modified") }
                    hdoc.undoManager.undo()
                    var restored = hdoc.byteCount == hexSeed.count
                    if restored {
                        for i in 0..<hexSeed.count where hdoc.byte(at: i) != hexSeed[i] { restored = false; break }
                    }
                    if !restored { failures += 1; print("FAIL [pixel] undo of replaceContents didn't restore") }
                } catch {
                    failures += 1
                    print("FAIL [pixel] replaceContents threw \(error)")
                }
            } else {
                failures += 1
                print("FAIL [pixel] PNG encode failed")
            }
        } else {
            failures += 1
            print("FAIL [hex] mmap failed")
        }

        if failures == 0 {
            print("SELFTEST PASS — content + line geometry + search + hex overlay verified over random edits")
            exit(0)
        } else {
            print("SELFTEST FAILED with \(failures) failure(s)")
            exit(1)
        }
    }

    /// Reference line bounds with the same CRLF semantics as PieceTable.
    private static func refLineBounds(_ b: [UInt8], _ line: Int) -> (Int, Int) {
        var starts = [0]
        for (i, c) in b.enumerated() where c == 0x0A { starts.append(i + 1) }
        let start = starts[line]
        var end: Int
        if line + 1 < starts.count {
            end = starts[line + 1] - 1            // back over the '\n'
            if end > 0, b[end - 1] == 0x0D { end -= 1 }   // and a CR if CRLF
        } else {
            end = b.count
        }
        return (start, end)
    }

    private static func debug(_ s: String) -> String {
        String(s.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
