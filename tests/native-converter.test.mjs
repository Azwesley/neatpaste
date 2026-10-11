import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, statSync, truncateSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { deflateRawSync, deflateSync } from 'node:zlib';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const helper = join(root, 'native/bin/neatpaste-convert');
const supported = process.platform === 'darwin';
let directory, fixtureTool;
let sequence = 0;

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function deflateDOCX(stored) {
  return zipEntries(storedEntries(stored));
}

function storedEntries(stored) {
  const entries = [];
  let cursor = 0;
  while (stored.readUInt32LE(cursor) === 0x04034b50) {
    const nameLength = stored.readUInt16LE(cursor + 26);
    const payload = cursor + 30 + nameLength + stored.readUInt16LE(cursor + 28);
    const size = stored.readUInt32LE(cursor + 18);
    entries.push({ name: stored.subarray(cursor + 30, cursor + 30 + nameLength), data: stored.subarray(payload, payload + size) });
    cursor = payload + size;
  }
  return entries;
}

function readDOCX(path) { return Object.fromEntries(storedEntries(readFileSync(path)).map(({ name, data }) => [name.toString(), data])); }

function pdfStream(dictionary, content) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
  return Buffer.concat([Buffer.from(`<< ${dictionary} /Length ${bytes.length} >>\nstream\n`), bytes, Buffer.from('\nendstream')]);
}

function writePDF(name, objects) {
  const parts = [Buffer.from('%PDF-1.4\n')], offsets = [0];
  let length = parts[0].length;
  objects.forEach((object, index) => {
    const data = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`), Buffer.isBuffer(object) ? object : Buffer.from(object), Buffer.from('\nendobj\n')]);
    offsets.push(length); parts.push(data); length += data.length;
  });
  parts.push(Buffer.from(`xref\n0 ${offsets.length}\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${length}\n%%EOF\n`));
  const path = join(directory, name); writeFileSync(path, Buffer.concat(parts)); return path;
}

function formPDF(name, pageOptions = '', contentSuffix = '', formMatrix = '2 0 0 1 5 6') {
  return writePDF(name, [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] ${pageOptions} /Resources << /Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >> >> /Contents 4 0 R >>`,
    pdfStream('', `BT /F1 14 Tf 30 350 Td (FORM_SENTINEL) Tj ET q 1 0 0 1 20 30 cm /Fm1 Do Q ${contentSuffix}`),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    pdfStream('/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Matrix [1 0 0 1 10 10] /Resources << /XObject << /Fm2 7 0 R >> >>', '/Fm2 Do'),
    pdfStream(`/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [${formMatrix}] /Resources << /XObject << /Im1 8 0 R >> >>`, 'q 40 0 0 30 0 0 cm /Im1 Do Q'),
    pdfStream('/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8', Buffer.from([255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255])),
  ]);
}

function zipEntries(entries) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const bytes = deflateRawSync(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc32(data), 14); local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc32(data), 16); central.writeUInt32LE(bytes.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28); central.writeUInt32LE(offset, 42);
    locals.push(local, name, bytes); centrals.push(central, name);
    offset += local.length + name.length + bytes.length;
  }
  const central = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, central, end]);
}

function documentFixture(xml, relations = '') {
  const entries = {
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    'word/document.xml': xml,
  };
  if (relations) entries['word/_rels/document.xml.rels'] = relations;
  return zipEntries(Object.entries(entries).map(([name, data]) => ({ name: Buffer.from(name), data: Buffer.from(data) })));
}

function execute(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 1024 * 1024, ...options });
  assert.equal(result.error, undefined, result.error?.message);
  return result;
}

function convert(input, format, output = join(directory, `output-${++sequence}.${format}`)) {
  const process = execute(helper, [], { input: JSON.stringify({ input, output, format }) });
  let response;
  assert.doesNotThrow(() => { response = JSON.parse(process.stdout); }, `Expected JSON, got: ${process.stdout}\n${process.stderr}`);
  assert.equal(process.status, response.ok ? 0 : 1, process.stderr);
  if (response.ok) assert.ok(existsSync(output));
  else assert.ok(!existsSync(output) || response.error === 'outputExists', 'Failed conversion must not leave an output');
  return { ...response, output };
}

before(() => {
  if (!supported) return;
  directory = mkdtempSync(join(tmpdir(), 'neatpaste-native-test-'));
  if (!existsSync(helper) || statSync(join(root, 'native/Converter.swift')).mtimeMs > statSync(helper).mtimeMs) {
    const result = execute(process.execPath, [join(root, 'scripts/build-native.mjs')]);
    assert.equal(result.status, 0, result.stderr);
  }
  const fixtureSource = join(directory, 'Fixtures.swift');
  fixtureTool = join(directory, 'fixtures');
  writeFileSync(fixtureSource, String.raw`
import Foundation
import AppKit
import ImageIO
import CoreGraphics
import CoreText
import PDFKit
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments[1] == "create" {
    let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: 8, height: 4))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = context.makeImage()!
    for (name, type, orientation) in [("alpha.png", "public.png", 1), ("rotate.jpg", "public.jpeg", 6), ("source.tiff", "public.tiff", 1), ("source.bmp", "com.microsoft.bmp", 1), ("source.heic", "public.heic", 1)] {
        let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }
    let animation = CGImageDestinationCreateWithURL(folder.appendingPathComponent("animated.gif") as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
    CGImageDestinationAddImage(animation, image, nil)
    CGImageDestinationAddImage(animation, image, nil)
    precondition(CGImageDestinationFinalize(animation))
    let pdf = NSMutableData()
    let consumer = CGDataConsumer(data: pdf as CFMutableData)!
    var rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let contextPDF = CGContext(consumer: consumer, mediaBox: &rect, nil)!
    for _ in 0..<101 { contextPDF.beginPDFPage(nil); contextPDF.fill(rect); contextPDF.endPDFPage() }
    contextPDF.closePDF()
    try! (pdf as Data).write(to: folder.appendingPathComponent("many-pages.pdf"))
    let locked = PDFDocument(data: pdf as Data)!
    locked.removePage(at: 100)
    precondition(locked.write(to: folder.appendingPathComponent("locked.pdf"), withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
    let twoPages = PDFDocument(data: pdf as Data)!
    while twoPages.pageCount > 2 { twoPages.removePage(at: twoPages.pageCount - 1) }
    precondition(twoPages.write(to: folder.appendingPathComponent("two-pages.pdf")))
    let mixedData = NSMutableData()
    let mixedConsumer = CGDataConsumer(data: mixedData as CFMutableData)!
    var mixedRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    let mixed = CGContext(consumer: mixedConsumer, mediaBox: &mixedRect, nil)!
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ target: CGContext) {
        target.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])), target)
    }
    for number in 1...2 {
        mixed.beginPDFPage(nil)
        mixed.setFillColor(CGColor(gray: 1, alpha: 1)); mixed.fill(mixedRect)
        label("第\(number)页 可编辑中文与图片", 44, 765, mixed)
        label("PAGE_\(number)_TEXT_SENTINEL", 44, 730, mixed)
        let bitmap = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.clear(CGRect(x: 0, y: 0, width: 240, height: 180))
        bitmap.setFillColor(number == 1 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 4, y: 4, width: 232, height: 172))
        mixed.draw(bitmap.makeImage()!, in: CGRect(x: 44, y: 500, width: 240, height: 180))
        label("中文图片说明 caption \(number)", 44, 465, mixed)
        mixed.saveGState(); mixed.translateBy(x: 380, y: 220); mixed.rotate(by: .pi / 6)
        mixed.draw(bitmap.makeImage()!, in: CGRect(x: -80, y: -60, width: 160, height: 120)); mixed.restoreGState()
        mixed.endPDFPage()
    }
    mixed.closePDF()
    try! (mixedData as Data).write(to: folder.appendingPathComponent("mixed-images.pdf"))
    let annotated = PDFDocument(data: mixedData as Data)!
    let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 40), forType: .freeText, withProperties: nil)
    note.contents = "A visible approval stamp"; annotated.page(at: 0)!.addAnnotation(note)
    precondition(annotated.write(to: folder.appendingPathComponent("annotated.pdf")))
    let profile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
    try! profile.write(to: folder.appendingPathComponent("rgb.icc"))
} else if CommandLine.arguments[1] == "rtf" {
    let attributed = try! NSAttributedString(data: Data(contentsOf: folder), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    FileHandle.standardOutput.write(Data(attributed.string.utf8))
} else {
    let source = CGImageSourceCreateWithURL(folder as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let corner = (image.width * image.height - 1) * 4
    func pixel(_ x: Int, _ y: Int) -> [Int] { let i = (y * image.width + x) * 4; return (0..<4).map { Int(pixels[i + $0]) } }
    var colored = 0
    for i in 0..<(image.width * image.height) { if Int(pixels[i * 4]) - Int(pixels[i * 4 + 1]) > 80 || Int(pixels[i * 4 + 2]) - Int(pixels[i * 4 + 1]) > 80 { colored += 1 } }
    let output: [String: Any] = ["type": CGImageSourceGetType(source)! as String, "width": image.width, "height": image.height, "colored": colored, "center": pixel(image.width / 2, image.height / 2), "upper": pixel(image.width / 2, image.height / 4), "lower": pixel(image.width / 2, image.height * 3 / 4), "left": pixel(image.width / 4, image.height / 2), "right": pixel(image.width * 3 / 4, image.height / 2), "corner": [Int(pixels[corner]), Int(pixels[corner + 1]), Int(pixels[corner + 2]), Int(pixels[corner + 3])]]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: output))
}
`);
  const build = execute('xcrun', ['swiftc', fixtureSource, '-o', fixtureTool]);
  assert.equal(build.status, 0, build.stderr);
  const fixtures = execute(fixtureTool, ['create', directory]);
  assert.equal(fixtures.status, 0, fixtures.stderr);
  writeFileSync(join(directory, 'source.webp'), Buffer.from('UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==', 'base64'));
});

after(() => { if (directory) rmSync(directory, { recursive: true, force: true }); });

test('Chinese text survives PDF extraction and DOCX preserves exact Unicode', { skip: !supported }, () => {
  const input = join(directory, '中文原文.txt');
  const text = '轻贴文件篮\n你好，世界！\nA useful local tool.\n第三段：保留中文 & <符号>。';
  writeFileSync(input, text);
  const pdf = convert(input, 'pdf');
  assert.equal(pdf.ok, true, pdf.error);
  assert.equal(pdf.warning, 'simpleReflow');
  assert.equal(readFileSync(pdf.output).subarray(0, 5).toString(), '%PDF-');
  const pdfText = convert(pdf.output, 'txt');
  assert.equal(pdfText.ok, true, pdfText.error);
  // macOS 14 PDFKit extracts these two fullwidth glyphs as their ASCII forms.
  // Permit only those observed PDF glyph mappings; do not normalize source/DOCX.
  const pdfComparable = value => value.replace(/！/g, '!').replace(/：/g, ':').replace(/\s/g, '');
  assert.equal(pdfComparable(readFileSync(pdfText.output, 'utf8')), pdfComparable(text));
  const docx = convert(input, 'docx');
  assert.equal(docx.ok, true, docx.error);
  assert.equal(readFileSync(docx.output).subarray(0, 2).toString(), 'PK');
  const docxText = convert(docx.output, 'txt');
  assert.equal(docxText.ok, true, docxText.error);
  assert.equal(readFileSync(docxText.output, 'utf8').trimEnd(), text);
  const docxPDF = convert(docx.output, 'pdf');
  assert.equal(docxPDF.ok, true, docxPDF.error);
});

test('text decoding accepts BOM-tagged UTF-16 and rejects invalid bytes without replacement', { skip: !supported }, () => {
  const input = join(directory, 'utf16.txt');
  writeFileSync(input, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('你好\r\nHello', 'utf16le')]));
  const result = convert(input, 'txt');
  assert.equal(result.ok, true, result.error);
  assert.equal(readFileSync(result.output, 'utf8'), '你好\nHello');
  const malformed = [
    [0xff, 0xfe, 0x00, 0xd8], // UTF-16LE unpaired high surrogate (macOS 14 regression).
    [0xff, 0xfe, 0x00, 0xdc], // UTF-16LE unpaired low surrogate.
    [0xfe, 0xff, 0xd8, 0x00], // UTF-16BE unpaired high surrogate.
    [0xfe, 0xff, 0xdc, 0x00], // UTF-16BE unpaired low surrogate.
    [0xff, 0xfe, 0x00, 0xd8, 0x41, 0x00], // High surrogate followed by plain text.
    [0xff, 0xfe, 0x41], // Truncated UTF-16 code unit.
    [0xc3, 0x28], // UTF-8 invalid continuation.
    [0xe2, 0x82], // UTF-8 truncated sequence.
    [0xc0, 0xaf], // UTF-8 overlong sequence.
    [0xed, 0xa0, 0x80], // UTF-8 encoded surrogate.
    [0xf4, 0x90, 0x80, 0x80], // Beyond Unicode U+10FFFF.
    [0x80], // Stray continuation byte.
  ];
  for (const bytes of malformed) {
    writeFileSync(input, Buffer.from(bytes));
    assert.equal(convert(input, 'txt').error, 'invalidEncoding', Buffer.from(bytes).toString('hex'));
  }
  // A literal replacement character is legitimate content, unlike decoder repair.
  const exact = '你好😀\uFFFD！：';
  for (const bytes of [Buffer.from(exact), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(exact, 'utf16le')]), Buffer.concat([Buffer.from([0xfe, 0xff]), Buffer.from(exact, 'utf16le').swap16()])]) {
    writeFileSync(input, bytes);
    const decoded = convert(input, 'txt');
    assert.equal(decoded.ok, true, decoded.error);
    assert.equal(readFileSync(decoded.output, 'utf8'), exact);
  }
});

test('Markdown conversion makes literal syntax explicit', { skip: !supported }, () => {
  const input = join(directory, 'notes.md');
  writeFileSync(input, '# 标题\n**保留原文**');
  const result = convert(input, 'txt');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.warning, 'markdownLiteral');
  assert.equal(readFileSync(result.output, 'utf8'), '# 标题\n**保留原文**');
});

test('image conversion flattens alpha to white, applies EXIF orientation, and creates one-page PDF', { skip: !supported }, () => {
  const jpg = convert(join(directory, 'alpha.png'), 'jpg');
  assert.equal(jpg.ok, true, jpg.error);
  assert.match(jpg.warning, /alphaFlattened/);
  const info = JSON.parse(execute(fixtureTool, ['inspect', jpg.output]).stdout);
  assert.deepEqual([info.width, info.height], [8, 4]);
  assert.ok(info.corner.slice(0, 3).every(value => value >= 245), `Transparent corner must be white: ${info.corner}`);
  const rotated = convert(join(directory, 'rotate.jpg'), 'png');
  assert.equal(rotated.ok, true, rotated.error);
  const rotation = JSON.parse(execute(fixtureTool, ['inspect', rotated.output]).stdout);
  assert.deepEqual([rotation.width, rotation.height], [4, 8]);
  const pdf = convert(join(directory, 'alpha.png'), 'pdf');
  assert.equal(pdf.ok, true, pdf.error);
  assert.equal(convert(pdf.output, 'txt').error, 'noEmbeddedText');
  for (const name of ['source.tiff', 'source.bmp', 'source.heic', 'source.webp']) assert.equal(convert(join(directory, name), 'png').ok, true, name);
});

test('guardrails reject unsupported conversions, corrupt files, oversized files and long text', { skip: !supported }, () => {
  const txt = join(directory, 'safe.txt');
  writeFileSync(txt, 'hello');
  assert.equal(convert(txt, 'png').error, 'unsupportedConversion');
  const executable = join(directory, 'not-a-document.exe');
  writeFileSync(executable, 'not a document');
  assert.equal(convert(executable, 'txt').error, 'unsupportedInput');
  for (const ext of ['png', 'pdf', 'docx']) {
    const input = join(directory, `corrupt.${ext}`);
    writeFileSync(input, 'not an actual file of this type');
    assert.equal(convert(input, ext === 'png' ? 'jpg' : 'txt').error, 'invalidInput');
  }
  writeFileSync(txt, 'x'.repeat(200_001));
  assert.equal(convert(txt, 'pdf').error, 'textTooLong');
  truncateSync(txt, 20 * 1024 * 1024 + 1);
  assert.equal(convert(txt, 'pdf').error, 'inputTooLarge');
  const image = join(directory, 'oversized.png');
  writeFileSync(image, '');
  truncateSync(image, 50 * 1024 * 1024 + 1);
  assert.equal(convert(image, 'jpg').error, 'inputTooLarge');
  assert.equal(statSync(image).size, 50 * 1024 * 1024 + 1);
});

test('PDF page limits and encryption apply to text extraction and rasterization', { skip: !supported }, () => {
  assert.equal(convert(join(directory, 'many-pages.pdf'), 'txt').error, 'tooManyPages');
  assert.equal(convert(join(directory, 'locked.pdf'), 'txt').error, 'passwordProtected');
  assert.equal(convert(join(directory, 'many-pages.pdf'), 'docx').error, 'tooManyPages');
  assert.equal(convert(join(directory, 'many-pages.pdf'), 'png').error, 'tooManyPages');
  assert.equal(convert(join(directory, 'locked.pdf'), 'jpg').error, 'passwordProtected');
});

test('conversion never overwrites an existing destination or its original input', { skip: !supported }, () => {
  const input = join(directory, 'preserve.txt');
  writeFileSync(input, 'original content');
  const output = join(directory, 'already-exists.pdf');
  writeFileSync(output, 'existing destination');
  assert.equal(convert(input, 'pdf', output).error, 'outputExists');
  assert.equal(readFileSync(output, 'utf8'), 'existing destination');
  assert.equal(convert(input, 'txt', input).error, 'outputExists');
  assert.equal(readFileSync(input, 'utf8'), 'original content');
});

test('pixel guard rejects oversized dimensions before allocating a decoded bitmap', { skip: !supported }, () => {
  const chunk = (type, bytes) => {
    const header = Buffer.alloc(8), checksum = Buffer.alloc(4);
    header.writeUInt32BE(bytes.length); header.write(type, 4);
    checksum.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type), bytes])));
    return Buffer.concat([header, bytes, checksum]);
  };
  // A valid monochrome 48 MP PNG needs only 6 MB of bit-packed source pixels.
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(8_000); ihdr.writeUInt32BE(6_000, 4); ihdr[8] = 1;
  const image = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(Buffer.alloc(6_000 * 1_001))), chunk('IEND', Buffer.alloc(0))]);
  const input = join(directory, 'too-many-pixels.png');
  writeFileSync(input, image);
  assert.equal(convert(input, 'jpg').error, 'imageTooLarge');
});

test('DOCX accepts ordinary deflate compression but rejects forged or oversized expansion metadata', { skip: !supported }, () => {
  const input = join(directory, 'zip-guard.txt');
  writeFileSync(input, '中文段落\n' + 'Repeated words '.repeat(200));
  const original = convert(input, 'docx');
  assert.equal(original.ok, true);
  const compressed = deflateDOCX(readFileSync(original.output));
  const archive = join(directory, 'compressed.docx');
  writeFileSync(archive, compressed);
  const extracted = convert(archive, 'txt');
  assert.equal(extracted.ok, true, extracted.error);
  assert.ok(readFileSync(extracted.output, 'utf8').startsWith('中文段落'));

  const central = compressed.readUInt32LE(compressed.length - 6);
  const forged = Buffer.from(compressed);
  forged.writeUInt32LE(0, central + 24);
  writeFileSync(archive, forged);
  assert.equal(convert(archive, 'txt').error, 'invalidInput');
  forged.writeUInt32LE(40 * 1024 * 1024 + 1, central + 24);
  writeFileSync(archive, forged);
  assert.equal(convert(archive, 'txt').error, 'expandedDocumentTooLarge');
});

test('DOCX body extraction preserves Chinese, runs, tabs and table cells without fetching linked resources', { skip: !supported }, async () => {
  const requests = [];
  const server = createServer((request, response) => { requests.push(request.url); response.end('External content must never be requested'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const target = `http://127.0.0.1:${server.address().port}/external-resource.png`;
    const input = join(directory, 'external-resource.docx'), output = join(directory, 'external-resource.txt');
    const xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:t>中文</w:t></w:r><w:r><w:t>段落 &amp; &lt;符号&gt;</w:t><w:tab/><w:t>tail</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>左</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>右</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:hyperlink r:id="remote"><w:r><w:t>链接标题</w:t></w:r></w:hyperlink></w:p><w:p><w:r><w:drawing><a:blip xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" r:link="remote"/></w:drawing></w:r></w:p></w:body></w:document>';
    const relations = `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="remote" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="${target}" TargetMode="External"/></Relationships>`;
    writeFileSync(input, documentFixture(xml, relations));
    const reply = await new Promise((resolve, reject) => {
      const child = spawn(helper, [], { stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = '';
      const timer = setTimeout(() => { child.kill(); reject(new Error('Conversion timed out')); }, 5000);
      child.stdout.on('data', data => { stdout += data; });
      child.stderr.resume();
      child.on('error', reject);
      child.on('close', () => { clearTimeout(timer); try { resolve(JSON.parse(stdout)); } catch (error) { reject(error); } });
      child.stdin.end(JSON.stringify({ input, output, format: 'txt' }));
    });
    assert.equal(reply.ok, true, reply.error);
    assert.equal(readFileSync(output, 'utf8'), '中文段落 & <符号>\ttail\n左\t右\n链接标题\n\n');
    assert.deepEqual(requests, []);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('DOCX rejects custom XML entities without reading external files or expanding entity chains', { skip: !supported }, () => {
  const secret = join(directory, 'private-external.txt');
  writeFileSync(secret, 'PRIVATE_SENTINEL');
  for (const declaration of [`<!ENTITY external SYSTEM "file://${secret}">`, '<!ENTITY external "expanded custom entity">']) {
    const xml = `<!DOCTYPE w:document [${declaration}]><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>&external;</w:t></w:r></w:p></w:body></w:document>`;
    const input = join(directory, 'xml-entity.docx');
    writeFileSync(input, documentFixture(xml));
    assert.equal(convert(input, 'txt').error, 'invalidInput');
  }
});

test('every advertised image output is a real decodable format and WebP encoding remains unsupported', { skip: !supported }, () => {
  const types = { png: 'public.png', jpg: 'public.jpeg', heic: 'public.heic', tiff: 'public.tiff', bmp: 'com.microsoft.bmp', gif: 'com.compuserve.gif' };
  for (const [format, type] of Object.entries(types)) {
    const result = convert(join(directory, 'alpha.png'), format);
    assert.equal(result.ok, true, `${format}: ${result.error}`);
    const inspected = JSON.parse(execute(fixtureTool, ['inspect', result.output]).stdout);
    assert.equal(inspected.type, type, format);
    assert.deepEqual([inspected.width, inspected.height], [8, 4], format);
    if (format === 'gif') assert.match(result.warning, /gifPaletteLimited/);
    if (format !== 'png') assert.equal(convert(result.output, 'png').ok, true, `Decode ${format}`);
  }
  assert.equal(convert(join(directory, 'alpha.png'), 'webp').error, 'unsupportedConversion');
  const animated = convert(join(directory, 'animated.gif'), 'png');
  assert.equal(animated.ok, true, animated.error);
  assert.match(animated.warning, /firstImageOnly/);
  const heif = join(directory, 'source.heif');
  writeFileSync(heif, readFileSync(join(directory, 'source.heic')));
  assert.equal(convert(heif, 'png').ok, true);
});

test('RTF, HTML and Markdown exports preserve text and escape active markup', { skip: !supported }, () => {
  const input = join(directory, 'document-exports.txt');
  const text = '中文与 emoji 😀\nA\tB {braces} \\slash\n<script>alert("no")</script> & <img src="https://example.com/a">';
  writeFileSync(input, text);
  const rtf = convert(input, 'rtf');
  assert.equal(rtf.ok, true, rtf.error);
  assert.ok(readFileSync(rtf.output, 'utf8').startsWith('{\\rtf1'));
  assert.equal(execute(fixtureTool, ['rtf', rtf.output]).stdout, text);
  const markdown = convert(input, 'md');
  assert.equal(markdown.ok, true, markdown.error);
  assert.equal(readFileSync(markdown.output, 'utf8'), text);
  const html = convert(input, 'html');
  assert.equal(html.ok, true, html.error);
  const source = readFileSync(html.output, 'utf8');
  assert.ok(source.startsWith('<!doctype html>'));
  assert.ok(source.includes('中文与 emoji 😀'));
  assert.ok(source.includes('&lt;script&gt;'));
  assert.ok(source.includes("default-src 'none'"));
  assert.equal(source.includes('<script>'), false);
  assert.equal(source.includes('<img '), false);
});

test('PDF exports editable text formats with explicit reflow warnings and rasterizes only page one', { skip: !supported }, () => {
  const text = 'PDF 中文转换\nA searchable document.';
  const input = join(directory, 'pdf-reflow.txt');
  writeFileSync(input, text);
  const pdf = convert(input, 'pdf');
  assert.equal(pdf.ok, true, pdf.error);
  for (const format of ['txt', 'md', 'docx', 'rtf', 'html']) {
    const result = convert(pdf.output, format);
    assert.equal(result.ok, true, `${format}: ${result.error}`);
    assert.match(result.warning, /pdfTextReflow/);
    if (format === 'docx') {
      const extracted = convert(result.output, 'txt');
      assert.equal(extracted.ok, true);
      assert.equal(readFileSync(extracted.output, 'utf8').replace(/\s/g, ''), text.replace(/\s/g, ''));
    } else if (format === 'rtf') {
      assert.equal(execute(fixtureTool, ['rtf', result.output]).stdout.replace(/\s/g, ''), text.replace(/\s/g, ''));
    }
  }
  for (const format of ['png', 'jpg']) {
    const result = convert(join(directory, 'two-pages.pdf'), format);
    assert.equal(result.ok, true, result.error);
    assert.match(result.warning, /firstPageOnly/);
    const image = JSON.parse(execute(fixtureTool, ['inspect', result.output]).stdout);
    assert.deepEqual([image.width, image.height], [200, 200]);
    assert.equal(image.type, format === 'png' ? 'public.png' : 'public.jpeg');
  }
});

test('CSV, TSV and JSON round-trip Chinese, quotes, embedded newlines, empty cells and exact string values', { skip: !supported }, () => {
  const csv = join(directory, 'quoted-data.csv');
  writeFileSync(csv, '名称,内容,编号,空白\r\n张三,"他说 ""你好""\r\n第二行",00123,\r\n李四,"tab\there",900719925474099312345,""\r\n');
  const expected = [['名称', '内容', '编号', '空白'], ['张三', '他说 "你好"\n第二行', '00123', ''], ['李四', 'tab\there', '900719925474099312345', '']];
  const json = convert(csv, 'json');
  assert.equal(json.ok, true, json.error);
  assert.deepEqual(JSON.parse(readFileSync(json.output, 'utf8')), expected);
  for (const format of ['csv', 'tsv']) {
    const delimited = convert(json.output, format);
    assert.equal(delimited.ok, true, delimited.error);
    const roundtrip = convert(delimited.output, 'json');
    assert.equal(roundtrip.ok, true, roundtrip.error);
    assert.deepEqual(JSON.parse(readFileSync(roundtrip.output, 'utf8')), expected);
  }
  const tsv = convert(csv, 'tsv');
  assert.equal(tsv.ok, true, tsv.error);
  const backCSV = convert(tsv.output, 'csv');
  assert.equal(backCSV.ok, true, backCSV.error);
  const backJSON = convert(backCSV.output, 'json');
  assert.deepEqual(JSON.parse(readFileSync(backJSON.output, 'utf8')), expected);
});

test('PDF to Word embeds every page image at its physical size and keeps complete editable text lines', { skip: !supported }, () => {
  const result = convert(join(directory, 'mixed-images.pdf'), 'docx');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.warning, 'pdfImagesReflow');
  const entries = readDOCX(result.output), xml = entries['word/document.xml'].toString();
  const media = Object.entries(entries).filter(([name]) => name.startsWith('word/media/'));
  assert.equal(media.length, 4);
  const relationships = entries['word/_rels/document.xml.rels'].toString();
  assert.equal((relationships.match(/Target="media\/image\d+\.png"/g) ?? []).length, 4);
  assert.equal(relationships.includes('TargetMode="External"'), false);
  assert.match(entries['[Content_Types].xml'].toString(), /Extension="png" ContentType="image\/png"/);
  for (const number of [1, 2]) {
    assert.match(xml, new RegExp(`<w:t[^>]*>PAGE_${number}_TEXT_SENTINEL</w:t>`), 'Font runs on one baseline must remain one editable line');
    assert.match(xml, new RegExp(`中文图片说明 caption ${number}`));
  }
  assert.equal((xml.match(/w:type="page"/g) ?? []).length, 1);
  assert.ok(xml.indexOf('PAGE_1_TEXT_SENTINEL') < xml.indexOf('rIdImage1'));
  assert.ok(xml.indexOf('rIdImage2') < xml.indexOf('PAGE_2_TEXT_SENTINEL'));
  const extents = [...xml.matchAll(/<wp:extent cx="(\d+)" cy="(\d+)"/g)].map(match => [Number(match[1]) / 12700, Number(match[2]) / 12700]);
  for (const [index, [, data]] of media.entries()) {
    assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    const path = join(directory, `embedded-${index}.png`); writeFileSync(path, data);
    const image = JSON.parse(execute(fixtureTool, ['inspect', path]).stdout);
    assert.ok(image.colored > image.width * image.height * 0.4, `Image ${index} must contain the actual colored picture`);
    const primary = index < 2 ? 0 : 2;
    // CoreGraphics converts the source profile; compare the dominant channel.
    assert.ok(image.center[primary] > 200 && image.center[primary] - image.center[1] > 120, `Wrong page/color for image ${index}: ${image.center}`);
    if (index % 2 === 0) {
      assert.ok(Math.abs(image.width - 480) <= 2 && Math.abs(image.height - 360) <= 2, `${image.width}x${image.height}`);
      assert.ok(Math.abs(extents[index][0] - 240) <= 1 && Math.abs(extents[index][1] - 180) <= 1, JSON.stringify(extents[index]));
      assert.ok(image.corner.slice(0, 3).every(value => value >= 245), 'Transparent edge must be white');
    } else assert.ok(Math.abs(image.width / image.height - 198.5641 / 183.923) < 0.02, 'Rotated picture aspect ratio');
  }
});

test('PDF Form transforms, page rotation and nonzero CropBox keep image pixels and aspect ratios', { skip: !supported }, () => {
  for (const [name, options, dimensions] of [['form.pdf', '', [160, 60]], ['form-rotated.pdf', '/CropBox [10 20 290 390] /Rotate 90', [60, 160]]]) {
    const result = convert(formPDF(name, options), 'docx');
    assert.equal(result.ok, true, result.error);
    assert.equal(result.warning, 'pdfImagesReflow');
    const entries = readDOCX(result.output), xml = entries['word/document.xml'].toString();
    assert.match(xml, /FORM_SENTINEL/);
    const media = Object.entries(entries).filter(([key]) => key.startsWith('word/media/'));
    assert.equal(media.length, 1);
    const path = join(directory, `${name}.png`); writeFileSync(path, media[0][1]);
    const image = JSON.parse(execute(fixtureTool, ['inspect', path]).stdout);
    assert.deepEqual([image.width, image.height], dimensions);
    assert.ok(image.colored > image.width * image.height * 0.95, 'Nested image crop cannot be blank');
    const colors = options ? [image.left, image.right] : [image.upper, image.lower];
    assert.ok(colors.some(color => color[0] > 240 && color[2] < 20) && colors.some(color => color[2] > 240 && color[0] < 20), JSON.stringify(colors));
  }
});

test('PDF ICCBased numeric scn colors do not turn editable text into page screenshots', { skip: !supported }, () => {
  const input = writePDF('icc-scn.pdf', [
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> /ColorSpace << /Cs1 [/ICCBased 6 0 R] >> /XObject << /Im1 7 0 R >> >> /Contents 4 0 R >>',
    pdfStream('', '/Cs1 cs 1 1 1 scn 0 0 300 400 re f 0 0 0 scn BT /F1 14 Tf 30 350 Td (ICC_EDITABLE_SENTINEL) Tj ET q 80 0 0 40 40 100 cm /Im1 Do Q'),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', pdfStream('/N 3', readFileSync(join(directory, 'rgb.icc'))),
    pdfStream('/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8', Buffer.from([255, 0, 0])),
  ]);
  const result = convert(input, 'docx');
  assert.equal(result.ok, true, result.error); assert.equal(result.warning, 'pdfImagesReflow');
  assert.match(readDOCX(result.output)['word/document.xml'].toString(), /ICC_EDITABLE_SENTINEL/);
});

test('text painted over a PDF image stays in that image without duplicate editable paragraphs', { skip: !supported }, () => {
  const result = convert(formPDF('overlay.pdf', '', 'BT /F1 12 Tf 40 55 Td (OVERLAY_IN_IMAGE) Tj ET BT /F1 12 Tf 30 300 Td (OUTSIDE_EDITABLE) Tj ET'), 'docx');
  assert.equal(result.ok, true, result.error);
  assert.equal(result.warning, 'pdfImagesReflow,pdfTextInImages');
  const entries = readDOCX(result.output), xml = entries['word/document.xml'].toString();
  assert.equal(xml.includes('OVERLAY_IN_IMAGE'), false);
  assert.match(xml, /OUTSIDE_EDITABLE/);
  assert.match(xml, /FORM_SENTINEL/);
  const image = entries['word/media/image1.png'];
  assert.ok(image.readUInt32BE(16) > 160, 'Image expands to include the complete overlaid text');
});

test('image-only PDFs embed real pictures and complex vector/inline pages use explicit visual fallback', { skip: !supported }, () => {
  const scanned = convert(join(directory, 'alpha.png'), 'pdf');
  const scanWord = convert(scanned.output, 'docx');
  assert.equal(scanWord.ok, true, scanWord.error);
  assert.match(scanWord.warning, /pdfImagesReflow/);
  assert.equal(Object.keys(readDOCX(scanWord.output)).filter(key => key.startsWith('word/media/')).length, 1);
  for (const [name, drawing] of [['vector', '1 0 0 rg 40 100 80 40 re f'], ['inline', 'q 80 0 0 40 40 100 cm BI /W 1 /H 1 /CS /RGB /BPC 8 /F /AHx ID ff0000> EI Q']]) {
    const input = writePDF(`${name}.pdf`, [
      '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
      pdfStream('', `BT /F1 14 Tf 30 350 Td (VISIBLE_IN_IMAGE) Tj ET ${drawing}`),
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ]);
    const result = convert(input, 'docx');
    assert.equal(result.ok, true, result.error); assert.match(result.warning, /pdfVisualFallback/);
    const entries = readDOCX(result.output);
    assert.equal(entries['word/document.xml'].toString().includes('VISIBLE_IN_IMAGE'), false, 'Visual fallback must not duplicate page text');
    const path = join(directory, `${name}-page.png`); writeFileSync(path, entries['word/media/image1.png']);
    const image = JSON.parse(execute(fixtureTool, ['inspect', path]).stdout);
    assert.deepEqual([image.width, image.height], [600, 800]);
    assert.ok(image.colored > 10_000, `${name} visual must be in embedded image`);
  }
});

test('PDF Word conversion stops on unsupported annotations, malformed transforms and scanner budgets', { skip: !supported }, () => {
  assert.equal(convert(join(directory, 'annotated.pdf'), 'docx').error, 'pdfUnsupportedAnnotation');
  assert.equal(convert(join(directory, 'locked.pdf'), 'docx').error, 'passwordProtected');
  assert.equal(convert(join(directory, 'many-pages.pdf'), 'docx').error, 'tooManyPages');
  assert.equal(convert(formPDF('bad-form.pdf', '', '', '1 0 0 1 2'), 'docx').error, 'invalidInput');
  assert.equal(convert(formPDF('too-complex.pdf', '', 'q Q '.repeat(100_001)), 'docx').error, 'pdfImageLimit');
});

test('data conversion preserves formula-looking strings and warns only for spreadsheet text exports', { skip: !supported }, () => {
  const input = join(directory, 'formula-data.json');
  const values = [['=1+1', '+cmd', '-2+3', '@name', '-12.5', '00123']];
  writeFileSync(input, JSON.stringify(values));
  for (const format of ['csv', 'tsv']) {
    const result = convert(input, format);
    assert.equal(result.ok, true, result.error);
    assert.equal(result.warning, 'spreadsheetFormulaLike');
    const roundtrip = convert(result.output, 'json');
    assert.equal(roundtrip.ok, true, roundtrip.error);
    assert.equal(roundtrip.warning, undefined);
    assert.deepEqual(JSON.parse(readFileSync(roundtrip.output, 'utf8')), values);
  }
  writeFileSync(input, JSON.stringify([['-12.5', '+3', '-2e3']]));
  assert.equal(convert(input, 'csv').warning, undefined);
});

test('data parsing rejects malformed quoting, ragged rows and ambiguous JSON types', { skip: !supported }, () => {
  const csv = join(directory, 'invalid-data.csv');
  for (const content of ['', 'a,b\nonly-one', 'a,"unterminated', 'a,"closed"junk', 'a,unquoted"quote']) {
    writeFileSync(csv, content);
    assert.equal(convert(csv, 'json').error, 'invalidTable', content);
  }
  const json = join(directory, 'invalid-data.json');
  for (const content of [{ name: 'value' }, [{ name: 'value' }], [[9007199254740992]], [[true]], [[null]], [['mixed', 1]]]) {
    writeFileSync(json, JSON.stringify(content));
    assert.equal(convert(json, 'csv').error, 'unsupportedJSONShape', JSON.stringify(content));
  }
  for (const content of [[], [[]], [['one'], ['two', 'three']], [['\u0000']]]) {
    writeFileSync(json, JSON.stringify(content));
    assert.equal(convert(json, 'csv').error, 'invalidTable', JSON.stringify(content));
  }
  writeFileSync(csv, ','.repeat(50_000) + '\n');
  assert.equal(convert(csv, 'json').error, 'tooManyCells');
  writeFileSync(csv, 'x'.repeat(200_001));
  assert.equal(convert(csv, 'tsv').error, 'textTooLong');
  writeFileSync(csv, 'a,b');
  assert.equal(convert(csv, 'pdf').error, 'unsupportedConversion');
});
