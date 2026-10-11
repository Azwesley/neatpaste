# Interface references for v0.4.2

Reviewed on 2026-10-11. This iteration follows Apple’s compact system utilities. It replaces the previous self-directed artwork, slogans and format-card layout. The links below were opened and inspected; no third-party product is claimed as a studied reference.

| Official reference | Observed principle | NeatPaste application |
| --- | --- | --- |
| [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Materials establish hierarchy and admit background color. Standard materials belong in content surfaces; use Liquid Glass sparingly for controls/navigation. Legibility takes priority. | A single reusable macOS Popover material under the window, with a restrained tint and opaque text. Standard controls sit on this surface without multiple decorative glass cards. |
| [Apple: AirDrop on Mac, macOS Tahoe 26](https://support.apple.com/zh-cn/guide/mac-help/mh35868/26/mac/26) | The official Mac/iPhone illustration shows a compact transfer dialog with file context and a small action area. The guide describes dragging files to an AirDrop recipient in Finder. | A small drop target, file-focused content, short toolbar and a direct completion action. NeatPaste converts locally; it does not use AirDrop. |

The collapsed capsule is an original adaptation of the user’s Dynamic Island request. System fonts, neutral materials, familiar control proportions and a system-blue primary action create consistency with macOS. The SVG tray/file symbols, CSS, arrangement and product identity are original project code; no Apple screenshot, wallpaper, logo or SF Symbols asset is bundled. Browser preview wallpaper is a CSS gradient.

The native material is NSVisualEffectView, not a claim to implement Apple’s Liquid Glass renderer. The app is independent and has no Apple endorsement. The resulting design is implemented code, not an Apple UI screenshot or concept mockup.
