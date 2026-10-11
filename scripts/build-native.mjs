import { mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform !== 'darwin') {
  console.log('Native file conversion is supported on macOS. The browser interface is a visual preview only.');
  process.exit(0);
}
const target = process.env.NEATPASTE_TARGET || process.env.TAURI_ENV_TARGET_TRIPLE || `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-apple-darwin`;
const architecture = target.startsWith('aarch64') || target.startsWith('arm64') ? 'arm64' : target.startsWith('x86_64') ? 'x86_64' : null;
if (!architecture) throw new Error(`Unsupported native conversion target: ${target}`);
mkdirSync(resolve(root, 'native/bin'), { recursive: true });
const result = spawnSync('xcrun', ['swiftc', '-O', '-target', `${architecture}-apple-macosx13.3`,
  '-framework', 'AppKit', '-framework', 'ImageIO', '-framework', 'PDFKit', '-framework', 'CoreGraphics', '-framework', 'CoreText', '-framework', 'UniformTypeIdentifiers', '-framework', 'AVFoundation', '-lz',
  resolve(root, 'native/Converter.swift'), '-o', resolve(root, 'native/bin/neatpaste-convert')], { stdio: 'inherit' });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
