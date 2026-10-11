> Historical report for the retired v0.1 text-workbench interface. These results do not describe the v0.2 file basket.

# v0.1.0 validation record

Date: 2026-10-10. This describes the local first-release build, not a GitHub Actions run.

## Build and packaging

- Apple M4, 24 GB RAM, macOS 26.6.2; ARM64 release build.
- `npm test`: 24 passed, 0 failed (17 transformation cases, 7 UI state cases).
- `npm run build`: passed; JavaScript 28.69 kB, CSS 12.90 kB before compression.
- `cargo fmt --check` and `cargo clippy --locked -- -D warnings`: passed.
- `npm run tauri build -- --bundles app -- --locked`: passed.
- Bundle minimum system version: macOS 13.3. This oldest version was not physically tested.
- Complete app sealed with a local ad-hoc signature; `codesign --verify --deep --strict` passed. No Developer ID signature or Apple notarization.
- App files: 3,699,105 bytes. App ZIP: 1,700,802 bytes. Source ZIP omits installed dependencies, generated schemas, and compiled build outputs.
- ZIP integrity checked. Signature validation does not imply Gatekeeper distribution approval.

## Interface and native boundaries

The browser-hosted interface was exercised for all five sample transformations, exact TSV clipboard output and formula guarding, editable results, keyboard copying, language switching without rewriting user content, preference persistence, and clearing text on reload. Light and dark appearances were checked. The 760 × 600 minimum window layout had no horizontal overflow. No browser console errors were observed.

The actual signed Mac app launched successfully. A second launch left one native process, confirming single-instance handling. Mac UI automation was blocked by the machine's locked screen. Native clipboard interaction, menu-bar clicks, shortcut activation, hide/reopen behavior, and a complete native end-to-end interaction remain unverified. The screenshot in this repository is the browser-rendered interface, not a native-window screenshot.

Windows is deferred. Intel and older supported macOS versions were not run. The GitHub workflows are provided but have not been executed in a published repository.

## Memory sample

With the release app open to an empty window and left idle for about two minutes, `vmmap -summary <pid>` reported the following **physical footprint**. This is not RSS, virtual address space, or a guaranteed maximum.

| Process | Physical footprint |
| --- | ---: |
| NeatPaste | 24.2 MiB |
| WebKit WebContent | 31.5 MiB |
| WebKit GPU | 13.7 MiB |
| WebKit Networking | 5.36 MiB |
| Total at this sample | about 74.8 MiB |

The three WebKit processes started with NeatPaste and all disappeared when that app process was terminated. They were included in the total rather than reporting the host process alone. The system screen was locked during this sample; it is not an active-use benchmark. WebKit creates a networking helper even for this offline app. The application's production CSP permits local IPC only, with no remote network destination.

Memory varies with the OS, text length, graphics, and interactions. Startup and active-use peak measurements are not established. The app has no clipboard polling or repeating application timers; text work happens on input and temporary notification/debounce timers stop when finished.
