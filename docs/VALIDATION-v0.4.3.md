# v0.4.3 compatibility validation

Historical record: links below refer to the original repository and its past CI runs. The current repository is [Azwesley/neatpaste](https://github.com/Azwesley/neatpaste).

Date: 2026-10-11. Local tests ran on macOS 26.6.2 (25G83), Apple Silicon. This patch retains the compact interface from [v0.4.2](VALIDATION-v0.4.2.md) and fixes a text-decoding difference discovered by GitHub's macOS 14 runner during initial publication.

## Compatibility fix

Foundation's UTF-16 decoder repaired an unpaired surrogate on macOS 14, while the converter requires invalid input to be rejected. The helper now verifies Swift UTF-8/UTF-16 decoding by comparing encoded units with the original input. This rejects repaired, truncated and invalid sequences deterministically. Valid supplementary characters and literal U+FFFD are preserved. It does not normalize source text or change document/table values.

PDFKit on macOS 14 extracts fullwidth exclamation and colon glyphs as their ASCII forms in the synthetic PDF fixture. The PDF extraction assertion accepts only those two observed mappings. Direct text and DOCX preservation assertions remain exact; production PDF extraction is unchanged.

## Verification

- All 17 native integration tests pass locally after rebuilding the helper. The encoding test now covers 12 malformed UTF-8/UTF-16 inputs and valid UTF-8, UTF-16LE and UTF-16BE with Chinese, emoji, literal U+FFFD and fullwidth punctuation.
- The original v0.4.2 upload had two macOS 14 test failures; those logs prompted this fix. Live remote results are visible in [GitHub Actions](https://github.com/gnpwvm28mg-eng/neatpaste/actions).
- The UI and Rust behavior are unchanged apart from version metadata. v0.4.2 has seven passing frontend model tests, 19 passing Rust tests, formatting and strict Clippy evidence. Its native picker, format popup, JPG conversion, original-preservation check, Finder reveal and appearance/size checks are recorded in the linked report.
- The rebuilt unsigned ARM64 helper is 233,648 bytes, SHA256 `83dd70f1b9e117ccfcaffe1a31b4c29c67c962a77aabb558ad9b4321f19df437`.

## Distribution checks

Release packages are locally ad-hoc signed; helper and full-bundle strict signature checks are required before upload. ZIP members are compared byte for byte against the sealed app and current project source. Published downloads have separate SHA256SUMS.txt checksums. The source package includes English documentation, native screenshots, license and GitHub workflows, excluding dependencies, private documents, artifacts and build output.

Screenshots retain v0.4.2 filenames because the visual layout is unchanged. The app uses standard NSVisualEffectView material, not Apple's Liquid Glass renderer. No new memory benchmark is claimed. Physical cross-app dragging, global shortcut invocation, Intel hardware and the oldest supported macOS version remain outside verified device coverage. The packages are not Developer ID signed or Apple notarized.
