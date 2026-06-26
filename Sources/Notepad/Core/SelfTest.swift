import Foundation

/// Differential fuzz test: apply identical random edits to the PieceTable and to
/// a trivially-correct `[UInt8]` reference, then assert the content and every
/// line-geometry query agree. Run via `Notepad --selftest`.
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

        if failures == 0 {
            print("SELFTEST PASS — content + line geometry + search verified over 4000 random edits")
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
