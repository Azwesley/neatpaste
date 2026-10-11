# v0.4.0 validation record

Date: 2026-10-11. Tested on Apple Silicon (arm64), macOS 26.6.2 (25G83). This release replaces the desktop pet with a small top-screen capsule, expands real local formats, and adds optional conversion using a remembered format.

## Automated checks

| Area | Evidence |
| --- | --- |
| Frontend model | 7/7 tests pass: common formats, invalid entries, remembered selection, partial results, file sizes, safe automatic-conversion eligibility, PDF/table defaults |
| Swift helper | 17/17 integration tests pass, including real codec decoding for all advertised image outputs, Chinese and emoji text round-trips, PDF first-page images, editable text exports, lossless CSV/TSV/JSON strings, malformed inputs, limits and no-overwrite behavior |
| Rust host | 17/17 tests pass, including window geometry, conversion on the Documents filesystem, collision-safe atomic publication, timeouts, originals, symlink protection and fresh intake after a finished batch |
| Formatting and lint | cargo fmt and Clippy with -D warnings pass |
| Production build | Tauri release build succeeds; final JS index-DZbj9S2e.js (41,137 bytes), CSS index-D7b7e7bK.css (10,248 bytes) |
| Signing | Helper and full app sealed with local ad-hoc signatures; strict signature verification passes |
| App archive | ZIP integrity passes; sealed app files total 3,749,153 bytes (3.58 MiB), ARM64 ZIP 1,689,537 bytes (1.61 MiB) |
| Source archive | ZIP integrity passes; all 56 members match current project files, required lockfiles/workflows are present, dependencies/build output/private runtime data are excluded |
| Intel | Swift helper cross-compilation succeeds; no Intel device validation |

The packaged ARM64 helper SHA-256 is `768368e3110710cb3e2ad01d1b13289295c19f073997fcb934b6ba1a421eda07` before final ad-hoc resealing. The bundle helper was compared with the tested helper before signing. The signed bundled helper SHA-256 is `ee05d90550b6e965437258475eb484eba93817123af81edf8ea6dca5043a04b0`. Signing changes its bytes. Release archive checksums are recorded in `artifacts/SHA256SUMS.txt` by the packaging workflow.

## Native desktop verification

The final sealed release was launched from the build bundle, with Chinese and dark appearance. The resting window is 232 × 52 logical points, including transparent margins; the visible capsule is 220 × 40. Expansion is 384 × 440. Native captures at 2× resolution are saved in `docs/assets/neatpaste-island-native.jpg` and `neatpaste-island-expanded.jpg`.

Verified through the actual macOS picker and release application:

- CSV → JSON: exact Chinese strings, `00123`, `900719925474099312345`, quoted cells and embedded newlines retained. SHA-256 checks confirm originals remain unchanged.
- With automatic conversion enabled and JSON remembered, selecting the same CSV produces `格式转换-轻贴-1.json` without overwriting the first result. Both outputs have identical contents.
- Selecting a different TSV immediately after the completed batch automatically produces `next-table-轻贴.json`, retaining `0007` and exporting no duplicate of the previous CSV. This verifies the completed-queue fix in the final build.
- PNG → HEIC: successful output decoded by macOS ImageIO through `sips`, recognized as HEIC at the original 128 × 128 dimensions; the transparency warning is displayed.
- The Finder result button selects the actual exported file. This was verified on the v0.4 build immediately before the completed-queue fix; the reveal implementation is unchanged in the final build.
- Language change, settings open/close, the automatic-conversion toggle, pin on/off, compact/expanded transitions, Escape closing settings, and Return to the top collapsing the panel were exercised.

Automatic conversion was returned to its default off state after testing. Browser preview additionally verified language, appearance, settings and seven image-format choices. `neatpaste-island-preview.jpg` uses browser sample files and is only a UI preview. It is not native conversion evidence.

## Current memory sample

A single idle sample around 09:04 local time on an Apple M4 (Mac16,12), 24 GiB RAM, with the final release resting as an empty compact capsule:

- Main process PID 41450 and WebKit GPU 41452, Networking 41453, WebContent 41454 were explicitly attributed to `app.neatpaste.desktop`, resource coalition 101804, using `launchctl print pid/<PID>`.
- `footprint --noCategories -f bytes 41450 41452 41453 41454` reports a grouped Footprint of **63,261,720 bytes, about 60.3 MiB**. Per-process physical-footprint totals were about 60.7 MiB; main-process footprint alone was about 26.4 MiB.
- RSS totaled 219,088 KiB (about 214 MiB), including shared pages; it is a different accounting measure and is not interchangeable with exclusive memory. All four sampled CPU values were 0.0%.
- This is one idle sample, not an active conversion peak, sustained benchmark, or memory upper bound. The Vite development server had already stopped.

## Remaining device boundaries

Physical Finder/Desktop drag-and-drop, the drag hover reaction, moving the capsule by its handle, focus-loss collapse, and invoking the global shortcut have not been verified end to end in this iteration. Native file registration/conversion, queue handling and geometry have automated coverage; picker-based desktop conversion and automatic conversion were exercised directly. These do not establish success for the separate cross-app drag gesture.

There is no completed active-conversion memory benchmark or oldest-supported-macOS test. Installer size and capsule size do not establish runtime memory use. Windows is deferred. The package is ad-hoc signed, without Developer ID signing or Apple notarization.

## Conversion boundaries

- GIF output is static, 256 colors at most. Animated or multi-image inputs export frame 1 only.
- WebP is input-only. RTF and HTML are output-only.
- PDF → PNG/JPG exports page 1 only at 144 dpi. PDF → Word/text reflows embedded text without restoring layout or running OCR.
- DOCX reads main-body text; headers, footnotes, images and original styling are not preserved. Markdown syntax stays literal.
- Table JSON must be a rectangular array of arrays of strings. Formula-looking CSV/TSV values remain unchanged and produce a warning.

See the README for all input/output pairs and size limits. Exports are published atomically with macOS `renamex_np(RENAME_EXCL)`, keeping originals and numbering collisions.

## Historical reports

[v0.3 desktop pet](VALIDATION-v0.3.0.md), [v0.2 file basket](VALIDATION-v0.2.0.md), and [v0.1 text workbench](VALIDATION-v0.1.0.md) describe earlier releases. Their screenshots, measurements and test counts are not v0.4 evidence.
