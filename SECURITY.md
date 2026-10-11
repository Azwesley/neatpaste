# Security and privacy

NeatPaste v0.4.2 processes explicitly dropped or selected files locally. It has no conversion server, account, telemetry, clipboard watcher, or directory scanner. The installed app uses a native Swift conversion helper on demand.

## Boundary

- Native code registers selected files. The renderer works with queue identities rather than choosing arbitrary paths to read, convert, overwrite, or reveal.
- Original files remain unchanged. Exports are ordinary files in a `轻贴导出` folder next to each source, using a new name when a file already exists.
- Exported files persist until you delete them; no content history is saved by the app itself.
- Format and size limits reduce normal resource use, but a small compressed file can still represent large content. Treat malformed documents as untrusted decoder input.
- Document conversion extracts and reflows text; it is not a general document sanitizer. Exported text may contain formulas, URLs, or commands from the original and should not be treated as executable instructions.
- DOCX extraction reads the main document XML without resolving external resources; DTD and entity declarations are rejected. Separate headers, notes, comments, images, and styling are not exported.
- PDF extraction performs no OCR. Encryption, damaged files, unsupported encodings, or unavailable text can cause a reported failure.
- Removing metadata is not a promised privacy feature. Do not assume conversion strips every sensitive property from a file.

Local packages use ad-hoc signing, without a Developer ID distribution signature or Apple notarization. An ad-hoc signature check does not authenticate the publisher. Formal distribution should use the maintainer's signing credentials and notarization.

## Reporting

If GitHub private vulnerability reporting is enabled, use **Security → Report a vulnerability**. Include the version, OS, reproduction steps, and a synthetic input with no personal information.

If private reporting is unavailable, open an issue requesting a private contact channel without posting exploit details or sensitive files. The project does not promise a response SLA.

Security fixes target the latest maintained version. Earlier versions have no separate support commitment.
