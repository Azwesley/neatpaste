# v0.6.0 animated GIF validation

Date: 2026-10-11. Local checks ran on macOS 26.6.2 (25G83), Apple Silicon. Previous PDF-to-Word evidence is archived in [v0.5.0 validation](VALIDATION-v0.5.0.md); its conversion tests remain passing.

## Result and automated checks

MOV and MP4 use AVFoundation decoding and ImageIO GIF encoding. Output includes multiple frames, source orientation and centisecond-rounded timing. GIF settings allow 320/480/640 px maximum edge, 10/15/20 fps and infinite looping or one play; defaults are 480/15/loop. Smaller sources are not enlarged. Live Photo grouping requires one explicitly selected HEIC/HEIF/JPG/JPEG and one same-stem MOV from the same canonical directory in the same intake batch. Pairing uses filenames, not Apple asset metadata, and never scans neighboring files or the Photos library.

- Frontend model: **9 tests passed**; JavaScript syntax and production Vite build passed. Tests cover motion format intersection, separate quick-conversion family and recovery from invalid saved GIF settings.
- Rust host: **26 tests passed**, formatting and strict Clippy passed. New coverage includes explicit pairing, ambiguity and directory/intake boundaries, pair counting before the queue limit, companion deduplication, 100 MiB input limits, strict option validation and helper JSON. Completion layout survives collapse and settings visits; all-failed motion batches retain their retry controls.
- Swift helper: **26 integration tests passed**. New groups exercise real H.264 and HEVC, MOV and MP4, changing frame pixels, orientation and its asymmetric marker, loop metadata, final-frame delays, audio removal, 15-second/300-frame boundaries and rejected damaged, audio-only, oversized and invalid-option inputs. The existing static-image and document suites, including PDF pictures embedded in editable DOCX, remain passing.
- Release app build passed. GitHub CI runs the frontend on Linux and Rust/Swift checks on macOS 14; current runs are available in [Actions](https://github.com/gnpwvm28mg-eng/neatpaste/actions).

## Animation and interface checks

An independent Pillow pass decoded every output frame from three synthetic, moving 1.25-second fixtures. Contact sheets were inspected for the main and portrait outputs. All frame hashes were distinct.

| Output | Dimensions | Frames | Total delay | Loop extension | Bytes |
| --- | --- | ---: | ---: | --- | ---: |
| Default moving GIF | 480 × 270 | 19 | 1,250 ms | Infinite | 45,697 |
| Portrait GIF | 90 × 160 | 25 | 1,250 ms | Infinite | 28,697 |
| Single-play GIF | 320 × 180 | 13 | 1,250 ms | Absent | 19,124 |

The default 15 fps output distributes 60/70 ms delays and retains the final 50 ms. The single-play output uses 100 ms delays plus a final 50 ms. Portrait output honors the source's 90-degree preferred transform without upscaling; both moving content and the asymmetric orientation marker were checked. Actual playback can vary between GIF viewers.

The browser preview was checked in Chinese/light and English/dark appearances. Size, frame rate and loop preferences survived reload. A mixed photo/video batch offered GIF and explained that only the video animates; removing the video restored ordinary image formats and height. The single-video options fit without scroll overflow at the 332 × 360-point animation preset. Idle capsule dimensions are unchanged.

The signed v0.6.0 desktop app's interactive check was initially blocked by the Mac lock screen. Native picker and direct dragging for this release are not yet included in the verified coverage below.

## Resources and distribution

A single default conversion of the synthetic 640 × 360, 1.25-second MOV took **0.66 seconds elapsed** under `/usr/bin/time -l`. The helper reported **66,158,592 bytes maximum resident set size** (about 63.1 MiB) and **36,258,536 bytes peak memory footprint** (about 34.6 MiB). This measures one small conversion only, excluding the desktop app and WebKit processes; it is neither an idle-memory nor worst-case guarantee. The helper exits after each job. No FFmpeg, browser or Office runtime is added.

The signed app's files total **3,959,985 bytes** (about 3.78 MiB); its download ZIP is **1,771,173 bytes** (about 1.69 MiB). Video frames are processed individually in autorelease pools. Input is limited to 100 MiB, duration to 0.04–15 seconds and source frames to 40 megapixels. Output is capped at 300 frames, 125 million combined frame pixels and 50 MiB encoded bytes. These are input/work/output limits, not RAM limits. Metadata loading times out after 15 seconds, and the host stops a helper job after 120 seconds. External local and remote movie references are forbidden. DRM rejection is implemented but was not checked with an actual encrypted sample.

The helper and app passed strict ad-hoc signature verification. The app ZIP passed CRC checks, and every packaged file byte-matched the signed app. Source archives exclude dependencies, build products and local QA/user files. Release assets include independent SHA256 checksums. Packages are not Developer ID signed or Apple notarized.

A real iPhone Live Photo export, Photos-to-app dragging, global shortcut invocation, Intel hardware, the oldest supported macOS and Windows have not been device-validated. Synthetic MOV/MP4 and explicit-pair tests establish the conversion and filename-pairing behavior; they do not establish direct Photos interoperability or recreation of Photos' Live Photo effects.
