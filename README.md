# Notepad (macOS)

A native macOS clone of Windows 10 Notepad — small, fast to launch, low memory,
and built to open **multi-gigabyte** text files and scroll them instantly.

## Why it's fast on huge files

It does **not** use `NSTextView` (which loads the whole file into memory). Instead:

- **`mmap`** — the file is memory-mapped read-only, so opening costs ~nothing
  (the OS pages bytes in on demand). Opening 1.5 GB measured at ~5 ms.
- **Sparse line index** — a background thread scans for `\n` with `memchr`
  (~7 GB/s) and stores a byte offset every 4096th line, so index memory stays
  tiny even for hundreds of millions of lines.
- **Viewport renderer** — a custom flipped `NSView` draws only the ~50 lines
  visible in the scroll viewport each frame.
- **Piece table** (planned, M1) — edits go to a separate buffer; editing a 10 GB
  file costs memory proportional to the edits, not the file.

## UI

Styled after Windows 10 Notepad: in-window menu bar (File/Edit/Format/View/Help),
white text area, and the Win10 status bar (`Ln/Col`, zoom, line ending, encoding).

## Build & run

```sh
swift run                       # debug build + launch
swift run Notepad /path/to/file # open a file directly
./Scripts/bundle.sh             # produce build/Notepad.app
```

## Roadmap

- **M0 ✅** mmap + sparse index + viewport renderer (read-only). Opens multi-GB
  files instantly with fast scroll.
- **M1** Piece-table editing: caret, selection, keyboard input, undo/redo.
- **M2** Find/Replace, Go To, Save/Save As, encoding + line-ending detection,
  word wrap, font picker, zoom, status-bar wiring.
- **M3** Recent files, drag-drop, print, app icon, packaging/signing.
