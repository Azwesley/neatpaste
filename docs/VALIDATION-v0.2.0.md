> Historical report for v0.2. Its window-size, native interaction, package, and memory evidence must not be treated as v0.3 results.

# v0.2.0 validation record

Date: 2026-10-10. This file tracks the redesigned Mac file basket. It is not a report of a GitHub Actions run.

## Current status

The native app completed a real image conversion through its file picker. The final ARM64 bundle, helper, signatures, archive, and a bounded idle-memory snapshot have been checked. Remaining device-interaction gaps are listed below. No v0.1 metric is presented as v0.2 evidence.

| Area | Current evidence |
| --- | --- |
| Native helper | 11 integration tests pass, including the final bounded DOCX XML reader and external-resource checks |
| Native host | 6 Rust tests pass, including the real helper pipeline, preserved originals, collision-safe output, timeout cleanup, and rejected symlink export folders |
| Native build | Final ARM64 v0.2 application and Swift helper built; Rust formatting and Clippy checks pass; all 6 host tests rerun with the final helper |
| Native picker and image conversion | PNG selected in the real app, PNG/JPG/PDF options shown, JPG selected, conversion succeeded, transparency warning displayed, actual 128 × 128 JPEG revealed in Finder; source SHA-256 unchanged |
| Cross-app drag and drop | Not physically tested; the desktop locked again before this check |
| Window dragging, pinning, shortcut, and tray | Not revalidated end to end for v0.2 |
| Browser interface | Chinese/English, appearance modes, and settings modal checked; no errors observed |
| Frontend model | 5 tests pass |
| Final package | App: 3,710,289 bytes (3.54 MiB). ARM64 ZIP: 1,674,938 bytes (1.60 MiB). ZIP integrity check passes |
| Signatures | Helper and complete app locally ad-hoc signed; both pass strict verification. No Developer ID signature or Apple notarization |
| Idle and conversion memory | One locked-screen idle sample totals about 56.1 MiB physical footprint; active-use and conversion peaks not measured |
| Intel and oldest supported macOS | Not device-validated |
| Windows | Deferred |

The compact screenshot `docs/assets/neatpaste-basket.png` is an actual native v0.2 window capture. `docs/assets/neatpaste-basket-preview.png` shows the browser preview with a demonstration queue; it is not evidence of a native conversion. Native TXT conversion through the window and activation of the global shortcut were not tested before the desktop locked again.

## Conversion fixtures

The helper tests exercise Chinese UTF-8 text through PDF extraction and DOCX round trips, BOM-tagged UTF-16 and invalid encodings, literal Markdown, transparent PNG to white-background JPEG, EXIF rotation, image-to-PDF, and TIFF/BMP/HEIC/WebP decoding. They also cover damaged inputs, byte-size and text-length limits, PDF page limits and encryption, unsupported PDF-to-DOCX, existing output preservation, the 40-megapixel guard, bounded DOCX ZIP expansion, a linked external image with zero observed localhost requests, and rejection of external-file/custom XML entities.

Rust tests include a real Chinese TXT export through the bundled helper twice, preserving the original and using different completed filenames. Failure propagation, helper timeout termination, and temporary-output cleanup are exercised separately.

## Release memory snapshot

On an Apple M4 Mac with 24 GB RAM running macOS 26.6.2, the final sealed app was launched and sampled about 55 seconds after startup, with no conversion running. `vmmap -summary` reported physical footprint for the native process and three associated WebKit workers. Before/after launch process snapshots identified those workers.

| Process | Physical footprint |
| --- | ---: |
| NeatPaste | 20.5 MiB |
| WebKit GPU | 13.2 MiB |
| WebKit Networking | 5,553 KiB, approximately 5.42 MiB |
| WebKit WebContent | 17.0 MiB |
| Total at this sample | approximately 56.12 MiB |

Every sampled process reported 0.0% CPU at that instant. The Mac screen was locked during the sample. This is not an active-use, image-conversion, sustained-CPU, RSS, or peak-memory benchmark. The conversion helper was not active and conversion peak memory is not established. Memory varies with the OS, input dimensions, page count, graphics, and interactions. No v0.1-to-v0.2 performance comparison is claimed.

Local raw evidence was saved in `artifacts/v0.2-memory.json` and associated `vmmap` logs. The generated artifact directory is intentionally excluded from the source archive.

## What must be distinguished

A browser preview demonstrates interface behavior, not native conversion. A valid archive is not evidence of an operational drop target. Generated files must be inspected for real content, while input files must remain unchanged and existing exports must not be overwritten.

The intended input limits are 10 files, 50 MiB per image, 20 MiB per document, 40 megapixels per image, 100 PDF pages, and 200,000 UTF-16 text units. DOCX expansion is limited to 40 MiB and 2,000 entries; helper jobs time out after 120 seconds. Passing ordinary fixtures does not imply support for arbitrary Word layouts, encrypted PDFs, scanned-page OCR, or every malformed file.

## Historical reference

The [v0.1 report](VALIDATION-v0.1.0.md) describes the retired text-workbench interface. Its size, tests, and memory snapshot must not be used to describe v0.2. The native v0.1 clipboard flow and shortcut registration were subsequently checked, but those checks do not validate the new file basket.
