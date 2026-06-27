# FlashPad (macOS)

A fast, native macOS text editor in the spirit of the classic Windows Notepad —
small, quick to launch, low memory, and built to open **multi-gigabyte** text
files and scroll them instantly.

## Why it's fast on huge files

It does **not** use `NSTextView` (which loads the whole file into memory). Instead:

- **`mmap`** — the file is memory-mapped read-only, so opening costs ~nothing
  (the OS pages bytes in on demand). Opening 1.5 GB measured at ~5 ms.
- **Sparse line index** — a background thread scans for `\n` with `memchr`
  (~7 GB/s) and stores a byte offset every 4096th line, so index memory stays
  tiny even for hundreds of millions of lines.
- **Viewport renderer** — a custom flipped `NSView` draws only the ~50 lines
  visible in the scroll viewport each frame.
- **Piece table** — edits go to a separate buffer; the document is a list of
  slices into either the mmap'd original or an "add" buffer, so editing a 10 GB
  file costs memory proportional to the edits, not the file. Fuzz-tested against
  a reference model over thousands of random edits (`FlashPad --selftest`).
- **pread indexing** — the newline scan reads 4 MB chunks via `pread` instead of
  walking the mmap, so the whole file never enters our resident set. A 1.5 GB
  file sits at **~100 MB RSS** after open.

## UI

Styled after Windows 10 Notepad: in-window menu bar (File/Edit/Format/View/Help),
white text area, and the Win10 status bar (`Ln/Col`, zoom, line ending, encoding).

## Build & run

```sh
swift run                       # debug build + launch
swift run FlashPad /path/to/file # open a file directly
./Scripts/bundle.sh             # produce build/FlashPad.app
```

## Roadmap

- **M0 ✅** mmap + sparse index + viewport renderer (read-only). Opens multi-GB
  files instantly with fast scroll.
- **M1 ✅** Piece-table editing: caret, selection, keyboard input, undo/redo,
  cut/copy/paste, select-all, live Ln/Col status, dirty-title marker.
  Plus multi-window (one process, one document per window) and low-memory
  pread indexing (~100 MB RSS for a 1.5 GB file).
- **M2 ✅** Save / Save As (atomic, low-memory streaming), Find / Replace / Go To
  (memmem search over the piece table), encoding + line-ending detection (BOM,
  CRLF/LF/CR; native ending on Return), Word Wrap (visual-row renderer, ≤50k
  lines), Font picker + Zoom.
- **M3 ✅** Recent files (Open Recent menu, persisted), drag-drop open, Print
  (streams pages from the piece table), app icon, and a packaged ad-hoc-signed
  `FlashPad.app` via `Scripts/bundle.sh`.

### Remaining polish (future)
- Typing-run undo coalescing (currently per-character)
- Precise caret on single lines >20k chars (render cap)
- Word wrap + native editing for UTF-16 and very large files
- Developer-ID signing + notarization (currently ad-hoc signed for local use)
