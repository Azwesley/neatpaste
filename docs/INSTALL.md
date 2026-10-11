# Install NeatPaste v0.4.2

Requires Apple Silicon (M-series) and macOS 13.3 or later. Windows is planned for a later release. Intel builds are available through the build workflow but have not been validated on Intel hardware.

1. Download `NeatPaste-v0.4.2-macOS-arm64.zip` from [GitHub Releases](https://github.com/gnpwvm28mg-eng/neatpaste/releases/latest).
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

**Convert on drop** is off by default. When enabled, a new batch uses the last selected format for its file family, if every item supports it. The first batch still needs a format choice. Images, PDFs, documents and tables remember formats separately.

See the [format matrix](../README.md#conversion-matrix) and [validation record](VALIDATION.md). PDF image output is limited to page 1; PDF-to-Word reflows embedded text without preserving layout. There is no OCR.

To uninstall, quit and remove the app. Exported files remain where they were saved.

[中文使用说明](../README.zh-CN.md)
