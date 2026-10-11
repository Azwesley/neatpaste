# v0.4.1 visual refinement validation

Date: 2026-10-11. macOS 26.6.2 (25G83), Apple Silicon. This update redesigns the island with translucent graphite/silver surfaces, a warm orange file mark, original CSS file artwork, a useful empty-state picker action, descriptive format cards, clearer completion feedback and light/dark appearance.

## Checks

- Frontend model: 7 tests pass; Vite production build passes. Final assets: `index-D6xzMzVk.js` (44.31 kB) and `index-CIxcrWug.css` (17.13 kB).
- Host: all 17 Rust tests pass with the new 360 × 400 expanded window, unchanged 232 × 52 compact window and preserved top-center anchor. Formatting and strict Clippy pass.
- Conversion helper: unchanged from v0.4.0; its prior 17 integration tests remain historical conversion evidence, not a new run for this visual update.
- Browser: empty picker action, sample queue, all seven image output choices, selected state, Chinese/English, dark/light appearance, settings switches and modal close were checked. Keyboard Enter on JPG preserves focus on the selected button after rerendering. The preview does not run native conversions.
- Layout: two sample images and all image formats fit the smaller panel. Longer document notes, settings and larger queues can scroll. English format descriptions are concise and retain title tooltips. Checked state uses a check mark as well as color. Reduced-motion preferences disable transitions/animations; no idle animation, timer, remote font or raster asset was introduced.

## Native glass

The host uses one reusable macOS NSVisualEffectView with BehindWindow blending and Active Popover material. It is updated only when the window is created or expanded/collapsed, on the main thread, clipped with public CALayer rounding inside the six-point transparent margin. Existing Objective-C bindings are declared directly without introducing new crate versions, a new runtime, or a polling loop.

## Native and packaging evidence

The final signed release was restarted and inspected as a native macOS window. Compact 232 × 52 and expanded 360 × 400 captures show aligned round corners and the inset glass surface, without a rectangular effect outside the island. Dark and light appearance were both exercised. The empty-state Select files button opened the real native picker. A synthetic 128 × 128 PNG was selected, the JPG card changed the primary action to Convert to JPG, and conversion completed. ImageIO through `sips` decoded the output as a 128 × 128 JPEG, and `cmp` confirmed the PNG original unchanged. Completion and reset-to-empty states were also exercised. Native screenshots are `neatpaste-v041-native.jpg`, `neatpaste-v041-empty.jpg`, `neatpaste-v041-ready.jpg`, `neatpaste-v041-result.jpg` and `neatpaste-v041-light.jpg`; the showcase is a resized native capture. Browser glass previews are explicitly separate.

Helper and app strict ad-hoc signature checks pass. The sealed bundle totals 3,749,169 bytes (3.58 MiB); the ARM64 app ZIP is 1,692,932 bytes (1.61 MiB). ZIP integrity passes. The source archive is checked against the current source byte for byte, including lockfiles and CI/build workflows, excluding dependencies, artifacts and build output. Archive hashes are in `artifacts/SHA256SUMS.txt`.

## Boundaries

The format matrix and original-preservation behavior remain as documented in the README. PDF image output is page 1 only; PDF/Word text is reflowed; GIF is static. Physical cross-app file dragging, global shortcut invocation and oldest-supported-macOS/Intel devices are not newly verified by this UI update.

This release has no new memory benchmark. The approximately 60.3 MiB idle physical-footprint sample in [v0.4.0](VALIDATION-v0.4.0.md) describes that earlier binary, not a v0.4.1 measurement. Packages use ad-hoc signatures, without Developer ID signing or Apple notarization.
