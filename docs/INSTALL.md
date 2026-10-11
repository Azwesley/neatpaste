# Install NeatPaste v0.6.0

Requires Apple Silicon (M-series) and macOS 13.3 or later. Windows is planned for a later release. Intel builds are available through the build workflow but have not been validated on Intel hardware.

1. Download [`NeatPaste-v0.6.0-macOS-arm64.zip`](https://github.com/gnpwvm28mg-eng/neatpaste/releases/download/v0.6.0/NeatPaste-v0.6.0-macOS-arm64.zip) from GitHub Releases.
2. Unzip it and move `NeatPaste.app` to Applications.
3. Open the app. Drop a file onto the small capsule near the top of the screen, or click the capsule and choose **Choose Files…**.
4. Pick a format, click **Convert**, then **Show in Finder**.

Originals are preserved. Outputs are saved in a folder named `轻贴导出` beside each original, with numbered filenames when necessary. The output folder name is currently fixed in both interface languages.

The package has a local ad-hoc signature. It does not have Developer ID signing or Apple notarization; signature verification is not Apple approval. macOS may require a manual Open Anyway approval in System Settings → Privacy & Security. Only approve an app you trust. Do not disable Gatekeeper globally.

## Everyday controls

- **Escape:** close settings, then collapse the panel.
- **⌘O:** choose files.
- **⌘,**: open Settings and select English or Simplified Chinese, appearance, or optional conversion on drop.
- **⌘⇧Space:** show or hide the app.
- **⌘W:** hide the window; reopen it from the menu bar.
- Drag the left tray icon to reposition the capsule. **Return to the top** restores its initial placement.
- Quit from the menu bar. An active conversion queue finishes before exit.

**Convert on drop** is off by default. When enabled, a new batch uses the last selected format for its file family, if every item supports it. The first batch still needs a format choice. Images, PDFs, documents, tables and motion files remember formats separately. GIF size, frame rate and loop choices are stored locally and reused.

## Make an animated GIF

Add a local MOV or MP4 and choose GIF. Set the maximum long edge to 320, 480 or 640 pixels and the frame rate to 10, 15 or 20 fps. The defaults are 480 pixels, 15 fps and infinite looping; turn looping off for a single play. Small sources are not enlarged. GIFs contain no audio, and exact playback timing depends on the viewer.

Videos must be no larger than 100 MiB and between 0.04 and 15 seconds long. Longer or larger files produce an error instead of a partial export. Source frames are limited to 40 megapixels; animated GIF output is limited to 300 frames, 125 million combined frame pixels and 50 MiB. If needed, trim or export a shorter video before adding it, or reduce GIF size/frame rate when an output limit is reported. The source video remains unchanged.

For a Live Photo, export it from Photos using **File → Export → Export Unmodified Original**. This supplies a still photo and a MOV. Keep them together with the same filename stem, for example `IMG_1234.HEIC` and `IMG_1234.MOV`, then select and drop **both at once** from Finder. A HEIC, HEIF, JPG or JPEG and MOV in the same directory and incoming batch are paired into one queue item. Pairing uses their filenames; it does not check Apple's asset metadata. The GIF uses the MOV component, and both originals are retained. The MOV also works on its own.

A still photo alone, including HEIC, does not supply motion. Direct dragging from Photos may give only a still image, and Photos' Live Photo effects are not recreated. The app does not search the photo library or neighboring files. Existing GIF inputs still use the image converter and export only their first frame. Video conversion is verified with synthetic fixtures; real iPhone Live Photo export has not been device-validated.

See the [format matrix](../README.md#conversion-matrix) and [validation record](VALIDATION.md). PDF image output is limited to page 1; PDF-to-Word embeds rendered pictures alongside editable text; complex or scanned pages may be kept as full-page images. Text inside those images is not editable. There is no OCR or exact complex-layout reconstruction. Flatten visible non-link annotations into the PDF before converting.

To uninstall, quit and remove the app. Exported files remain where they were saved.

[中文使用说明](../README.zh-CN.md)
