# v0.3.0 validation record

Date: 2026-10-10. This version replaces the resting card with a tiny basket character with a face, feet, and visual feedback. The conversion matrix and native helper remain unchanged. The final build includes the native save fix and the immediate drag call.

## Current status

| Area | Current evidence |
| --- | --- |
| Compact desktop object | Native app launched, with an 88 × 88-point transparent window and character artwork; native capture saved at 2× resolution |
| Expanded panel | Native 336 × 480-point panel opened and collapsed from the desktop character; the basket stays anchored at bottom-right |
| Click, drag-to-move, right-click preferences | Native click opened the panel, pinning toggled, and browser preferences were checked; final drag and right-click native checks were blocked by the later screen lock |
| Character feedback | Native compact capture shows the face, arms, feet, count badge, and busy expression. Native drag/drop reaction was not physically verified |
| Native regression tests | 13 Rust tests pass on the actual Documents export filesystem, covering geometry, the real TXT-to-PDF helper pipeline, collision and symlink protection, timeout/failure cleanup, and preserved originals |
| Native file conversion | Final native host passed 13 tests on the actual Documents export path, including TXT-to-PDF twice, collision numbering, source preservation, and the atomic save fix; the earlier GUI run exposed and then blocked on the replaced hard-link path before the final rebuild |
| Build, signing, and archive | Final sealed app: 3,710,305 bytes (3.54 MiB); ARM64 ZIP: 1,677,445 bytes (1.60 MiB); ZIP integrity and strict ad-hoc signature verification pass |
| Browser interface | Light/dark, Chinese/English, settings modal, sample format selection, and collapse checked; no native drop success inferred from these checks |
| Memory and conversion peaks | Not measured for v0.3 |
| Intel and oldest supported macOS | Not device-validated |
| Windows | Deferred |

The final native build was launched again after the save and drag fixes, but the Mac locked before a second GUI conversion and drag pass. Browser screenshots and native tests are distinguished from those remaining interactions. A smaller window does not establish a smaller memory footprint. No v0.3 memory or active-conversion benchmark was taken.

The compact image `docs/assets/neatpaste-pet.png` is a native 176 × 176-pixel capture of the 88 × 88-point window, displayed at 88 points in the READMEs. `docs/assets/neatpaste-pet-working.png` is a working-state capture, not proof of completed conversion.

## Output publication

Live checking exposed a blocked hard-link save operation. The final host now publishes completed temporary outputs with `renamex_np(RENAME_EXCL)`. The no-overwrite path and a real TXT-to-PDF export were tested under the same Documents export location. Current releases do not impose the earlier hard-link/APFS/HFS+ requirement.

## What was checked in the native window

The native window was captured at 88 × 88 compact and 336 × 480 expanded sizes. The picker exposed PDF/TXT/Word choices for a Chinese TXT input. Busy feedback, collapse while busy, and pin on/off were checked before the final save-path fix. The final frontend build and 5 model tests pass; 13 host tests pass with the corrected native save path. The unchanged conversion helper previously passed its 11 tests. Cross-app file drag, character movement, right-click preferences, focus-triggered collapse, global shortcut activation, and final GUI conversion/reveal remain unverified.

## Historical reports

- [v0.2 file basket](VALIDATION-v0.2.0.md): larger card interface, tested image conversion, package checks, and a locked-screen memory sample.
- [v0.1 text workbench](VALIDATION-v0.1.0.md): the earlier text-only product.

These reports remain historical and are not v0.3 test or measurement results.
