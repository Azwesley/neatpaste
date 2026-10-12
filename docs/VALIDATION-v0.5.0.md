# v0.5.0 PDF-to-Word validation

Historical record: links below refer to the original repository and its past CI runs. The current repository is [Azwesley/neatpaste](https://github.com/Azwesley/neatpaste).

Date: 2026-10-11. Local checks ran on macOS 26.6.2 (25G83), Apple Silicon. The compact UI from [v0.4.2](VALIDATION-v0.4.2.md) and strict text decoding from [v0.4.3](VALIDATION-v0.4.3.md) are retained.

## Result

PDF-to-DOCX now writes PNG data into `word/media/` with internal DrawingML relationships. Ordinary PDF text becomes editable Word paragraphs. Pictures are rendered at 144 dpi, retain their displayed aspect ratio, and are placed among text in approximate reading order, with source-page breaks. No external image relationships or source paths are written into the output.

Complex vector/inline-image pages use an explicit full-page-image fallback. Text overlapping a picture stays in the picture to avoid duplication. Those cases report that text is not separately editable. Visible non-link annotations are rejected rather than omitted; users must flatten them first. This is not OCR or exact reconstruction of columns, tables, fonts or layout.

## Automated checks

- Frontend model: 7 tests passed; JavaScript syntax check and Vite production build passed.
- Rust host: 19 tests passed, `cargo fmt --check` passed, strict Clippy passed.
- Swift converter: 23 integration tests passed. Six new groups cover embedded PNGs and internal relationships, editable text lines and source page breaks, physical image sizes, transparency, rotated images, true nested Form transforms, nonzero CropBox and 90-degree rotation, ICC color state, overlaid text, scanned PDFs, vector/inline fallback, annotation rejection, malformed transforms and scan limits. Pixel-color checks distinguish actual image content from blank crops.
- Existing input, decoding, encryption, page-count, atomic output, image-format, document and table tests remain passing.
- GitHub's macOS 14 and Linux jobs are available in [Actions](https://github.com/gnpwvm28mg-eng/neatpaste/actions).

## Document and desktop checks

A two-page synthetic PDF contains selectable Chinese and English text, four colored image placements, transparent edges and 30-degree image rotation. The output has four real PNGs, complete editable sentinel lines, internal image relationships and one explicit source-page break. Its rendered two pages were inspected: Chinese/English text and all four images display, with no clipped pictures or overlapping paragraphs. Separate nested-Form outputs, including page rotation and a nonzero CropBox, were also rendered and inspected.

Rendering used the bundled headless LibreOffice and `render_docx.py`, with a temporary Fontconfig file pointing to the Mac's existing system fonts. The first renderer pass lacked CJK font discovery; configuring the QA renderer restored Chinese display without modifying the DOCX. LibreOffice and fonts are not bundled in NeatPaste. Pages also opened the DOCX and exposed editable Chinese/English body text and four independent image objects. Microsoft Word itself was not installed or tested.

The signed desktop app selected the two-page PDF through the native file picker and converted it to Word in `轻贴导出`. That output byte-matched the visually checked helper output: 58,071 bytes, SHA256 `1bb829e32bee2055d5d73f5016c008551ad2b8a8531f980caa48fcdc60e60ae8`. The original PDF checksum was unchanged. Format selection and completion guidance were checked in the native window. Longer exceptional warnings remain scrollable in the compact panel.

## Resource and distribution boundaries

The unsigned converter is 317,808 bytes, SHA256 `1d5d0474eda136f93f4f28336bea8c37fdaa60ee7dd4060d004dac36229ea1d2`. The app still uses system WebKit and macOS PDF/image APIs; no browser or Office runtime is added.

PDF-to-Word processing retains the 20 MiB input, 100-page, 200,000 UTF-16-unit and 120-second job limits. New limits include 40 megapixels per rendered page, 200 megapixels of total page rendering, 40 MiB of uncompressed DOCX entry content, 500 output images, bounded Form depth and scan work. Oversized work fails explicitly. Conversion-time memory varies with page dimensions and image data; no new idle or worst-case memory benchmark is claimed.

Release ZIPs receive strict ad-hoc signature and byte-for-byte packaging checks. Published ZIPs have independent SHA256 checksums. Source packages exclude dependencies, build output, local QA artifacts and private documents. Packages are not Developer ID signed or Apple notarized. Physical cross-app dragging, global shortcut invocation, Intel hardware, the oldest supported macOS version and Windows remain outside this release's verified coverage. The user's particular PDF was not available; document checks used synthetic fixtures.
