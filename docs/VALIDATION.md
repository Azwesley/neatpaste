# v0.4.2 Apple-style utility validation

Date: 2026-10-11. macOS 26.6.2 (25G83), Apple Silicon. This update replaces the decorative landing-page structure with a compact macOS utility: a short toolbar, file rows, a format popup, adaptive panel height and a primary Show in Finder action. Official sources and their actual influence are recorded in [REFERENCES.md](REFERENCES.md).

## Checks

- Frontend model: 7 tests pass. Vite release build passes; assets are `index-B8hF6mc1.js` (46,084 bytes) and `index-BpZiBkvD.css` (12,123 bytes). No new frontend dependency or idle animation was introduced.
- Rust host: 19 tests pass, including rejection of arbitrary layout sizes and preservation of the anchor through height changes near display edges. Formatting and strict Clippy pass. `set_layout` is registered and compiled in the release; Info.plist reports 0.4.2.
- Browser: Chinese and English, light and dark appearances, empty/single/two-file states, all seven image choices, settings, Escape and return-to-settings keyboard focus were exercised. A format change retains focus on the format control. Single-file and two-file content were measured without unintended content scrolling; long lists remain scrollable. The dialog is constrained to the panel, including in browser preview, instead of filling the browser viewport.
- Conversion helper: unchanged from v0.4.0. Its unsigned SHA256 remains `768368e3110710cb3e2ad01d1b13289295c19f073997fcb934b6ba1a421eda07`. The earlier 17 helper integration tests are historical evidence, not a new full-matrix run for this UI update.

## Native UI and conversion

The signed release was restarted and inspected as a real macOS application. Screenshots confirm the compact 208 × 48 window, empty 332 × 228 window, single-file 332 × 272 window and taller 332 × 398 settings panel. The visible capsule is 196 × 36 points after transparent margins. The reusable NSVisualEffectView remains clipped to the rounded surface and follows adaptive sizes without a rectangular material outside the panel.

The native Choose Files button opened the macOS file picker. A synthetic 128 × 128 PNG was selected. The format popup opened as a real WebKit/macOS menu; keyboard selection changed JPG → PDF → JPG, updated the warning and retained focus. Conversion produced `artifacts/qa-v042/轻贴导出/Sample-轻贴.jpg`. `sips` decoded it as a 128 × 128 JPEG; `cmp` confirmed the original PNG unchanged. The completed view displayed the transparency warning and a primary Show in Finder button. That button opened the output folder and selected the exact JPEG, verified in Finder’s accessibility tree. Returning to the app preserved the result. Dark/light appearance and Escape from settings were also exercised; Escape returned focus to Settings. An additional native English pass was captured for the GitHub project page; the app is left in English and light appearance.

Native captures: `neatpaste-v042-native.jpg`, `neatpaste-v042-light.jpg`, `neatpaste-v042-ready.jpg`, `neatpaste-v042-result.jpg`, and `neatpaste-v042-dark.jpg`. `neatpaste-v042-showcase.jpg` is a resized native result capture; `neatpaste-v042-preview.jpg` is a browser preview and is not native evidence.

## Packages

Helper and complete app strict ad-hoc signature checks pass. The sealed bundle totals 3,749,169 bytes (3.58 MiB). The ARM64 app ZIP is 1,693,702 bytes (1.62 MiB); archive integrity passes and all five sealed app files byte-match the built bundle. The source archive includes the current code, lockfiles, GitHub workflows, reference notes and this report, and excludes dependencies, artifacts and build output. Source members are checked byte for byte after packaging. Checksums are in `artifacts/SHA256SUMS.txt`.

## Boundaries

Physical cross-app file dragging, invoking the global shortcut, Intel hardware and the oldest supported macOS release were not newly verified. Batch height was exercised in browser preview and native geometry tests, not with a native ten-file UI run. PDF raster export remains page 1 only; document text reflows without original layout; GIF is static.

There is no new memory benchmark in this release. The approximately 60.3 MiB sample in [v0.4.0](VALIDATION-v0.4.0.md) describes that earlier binary. Smaller dimensions and fewer CSS rules are not memory measurements. Packages are ad-hoc signed without Developer ID or Apple notarization. The material is standard NSVisualEffectView, not Apple’s Liquid Glass renderer.
