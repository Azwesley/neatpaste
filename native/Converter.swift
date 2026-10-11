import Foundation
import AppKit
import ImageIO
import PDFKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
import zlib

// A one-request process: no clipboard, preferences, network, or persistent cache.
struct Request: Decodable { let input: String; let output: String; let format: String }
struct Reply: Encodable { let ok: Bool; var error: String?; var warning: String? }
struct ConversionError: Error { let code: String }
func fail(_ code: String) throws -> Never { throw ConversionError(code: code) }

let documentLimit = 20 * 1024 * 1024
let imageLimit = 50 * 1024 * 1024
let textLimit = 200_000
let pixelLimit = 40_000_000
let pageLimit = 100
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]
let documentExtensions: Set<String> = ["txt", "md", "docx", "pdf"]
let imageDestinationTypes = ["png": "public.png", "jpg": "public.jpeg", "heic": "public.heic", "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "gif": "com.compuserve.gif"]
let documentOutputFormats: Set<String> = ["txt", "md", "pdf", "docx", "rtf", "html"]
let tableFormats: Set<String> = ["csv", "tsv", "json"]
let cellLimit = 50_000

func checkedText(_ text: String) throws -> String {
    guard text.utf16.count <= textLimit else { try fail("textTooLong") }
    return text
}

func decodedText(_ data: Data) throws -> String {
    let bytes = [UInt8](data.prefix(3))
    let text: String?
    if bytes.starts(with: [0xFF, 0xFE]) {
        guard data.count % 2 == 0 else { try fail("invalidEncoding") }
        text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    } else if bytes.starts(with: [0xFE, 0xFF]) {
        guard data.count % 2 == 0 else { try fail("invalidEncoding") }
        text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    } else {
        text = String(data: data, encoding: .utf8)
    }
    guard var result = text, !result.contains("\0") else { try fail("invalidEncoding") }
    if result.first == "\u{FEFF}" { result.removeFirst() }
    return try checkedText(result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
}

func u16(_ data: Data, _ offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8)
}
func u32(_ data: Data, _ offset: Int) -> Int {
    u16(data, offset) | (u16(data, offset + 2) << 16)
}

func validateZIPPayload(_ data: Data, offset: Int, compressed: Int, expanded: Int, method: Int, checksum: Int, capture: Bool) throws -> Data? {
    try data.withUnsafeBytes { raw -> Data? in
        let input = raw.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        if method == 0 {
            guard compressed == expanded, Int(crc32(0, input, uInt(compressed))) == checksum else { try fail("invalidInput") }
            return capture ? data.subdata(in: offset..<offset + expanded) : nil
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { try fail("invalidInput") }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: input)
        stream.avail_in = uInt(compressed)
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var actual = 0
        var crc: uLong = 0
        var captured = Data()
        while true {
            let status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                let result = inflate(&stream, Z_NO_FLUSH)
                let produced = output.count - Int(stream.avail_out)
                actual += produced
                crc = crc32(crc, output.baseAddress, uInt(produced))
                if capture && actual <= expanded { captured.append(output.baseAddress!, count: produced) }
                return result
            }
            guard actual <= expanded else { try fail("invalidInput") }
            if status == Z_STREAM_END { break }
            guard status == Z_OK, stream.avail_out == 0 || stream.avail_in > 0 else { try fail("invalidInput") }
        }
        guard actual == expanded, Int(stream.total_in) == compressed, Int(crc) == checksum else { try fail("invalidInput") }
        return capture ? captured : nil
    }
}

// Validate all archive payloads, then expose only the document's XML text.
func validateDOCX(_ data: Data) throws -> Data {
    guard data.count >= 22 else { try fail("invalidInput") }
    var end: Int?
    for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
        if u32(data, offset) == 0x06054b50 && offset + 22 + u16(data, offset + 20) == data.count { end = offset; break }
    }
    guard let end, u16(data, end + 4) == 0, u16(data, end + 6) == 0 else { try fail("invalidInput") }
    let count = u16(data, end + 10)
    guard count > 0, count <= 2_000, count == u16(data, end + 8) else { try fail("invalidInput") }
    var offset = u32(data, end + 16)
    let centralStart = offset
    guard offset >= 0, offset + u32(data, end + 12) <= end else { try fail("invalidInput") }
    var expanded = 0
    var names = Set<String>()
    var documentXML: Data?
    for _ in 0..<count {
        guard offset + 46 <= end, u32(data, offset) == 0x02014b50 else { try fail("invalidInput") }
        let flags = u16(data, offset + 8)
        let method = u16(data, offset + 10)
        guard flags & 1 == 0, method == 0 || method == 8 else { try fail("invalidInput") }
        let size = u32(data, offset + 24)
        expanded += size
        guard expanded <= 40 * 1024 * 1024 else { try fail("expandedDocumentTooLarge") }
        let nameLength = u16(data, offset + 28)
        let length = 46 + nameLength + u16(data, offset + 30) + u16(data, offset + 32)
        guard offset + length <= end else { try fail("invalidInput") }
        guard let name = String(data: data.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8), !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { try fail("invalidInput") }
        guard names.insert(name).inserted else { try fail("invalidInput") }
        // ZIP64 sizes/offsets are intentionally unsupported in this small tool.
        let local = u32(data, offset + 42)
        guard local + 30 <= data.count, u32(data, local) == 0x04034b50 else { try fail("invalidInput") }
        let payload = local + 30 + u16(data, local + 26) + u16(data, local + 28)
        let compressed = u32(data, offset + 20)
        guard payload + compressed <= centralStart else { try fail("invalidInput") }
        let payloadData = try validateZIPPayload(data, offset: payload, compressed: compressed, expanded: size, method: method, checksum: u32(data, offset + 16), capture: name == "word/document.xml")
        if let payloadData { documentXML = payloadData }
        offset += length
    }
    guard names.contains("[Content_Types].xml"), let documentXML else { try fail("invalidInput") }
    return documentXML
}

final class DocumentTextReader: NSObject, XMLParserDelegate {
    var text = ""
    var length = 0
    var textDepth = 0
    var failure: String?
    var sawDocument = false
    let namespaces: Set<String> = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"]

    func append(_ value: String, parser: XMLParser) {
        guard failure == nil else { return }
        length += value.utf16.count
        guard length <= textLimit else { failure = "textTooLong"; parser.abortParsing(); return }
        text += value
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard namespaces.contains(namespaceURI ?? "") else { return }
        if name == "document" { sawDocument = true }
        if name == "t" { textDepth += 1 }
        if name == "tab" { append("\t", parser: parser) }
        if name == "br" || name == "cr" { append("\n", parser: parser) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 { append(string, parser: parser) }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard textDepth > 0, let string = String(data: data, encoding: .utf8) else { return }
        append(string, parser: parser)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard namespaces.contains(namespaceURI ?? "") else { return }
        if name == "t" { textDepth = max(0, textDepth - 1) }
        if name == "p" { append("\n", parser: parser) }
        if name == "tc" {
            if text.hasSuffix("\n") { text.removeLast(); length -= 1 }
            append("\t", parser: parser)
        }
        if name == "tr" {
            if text.hasSuffix("\t") { text.removeLast(); length -= 1 }
            append("\n", parser: parser)
        }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = "invalidInput"; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        failure = "invalidInput"; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = "invalidInput"; parser.abortParsing(); return nil
    }
}

func docxText(_ data: Data) throws -> String {
    let xml = try validateDOCX(data)
    let prefix = [UInt8](xml.prefix(4))
    let encoding: String.Encoding
    if prefix == [0xff, 0xfe, 0, 0] || prefix == [0x3c, 0, 0, 0] { encoding = .utf32LittleEndian }
    else if prefix == [0, 0, 0xfe, 0xff] || prefix == [0, 0, 0, 0x3c] { encoding = .utf32BigEndian }
    else if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0x3c, 0]) { encoding = .utf16LittleEndian }
    else if prefix.starts(with: [0xfe, 0xff]) || prefix.starts(with: [0, 0x3c]) { encoding = .utf16BigEndian }
    else { encoding = .utf8 }
    // OOXML never needs DTDs. Reject them before the parser sees any entity,
    // including encodings where a raw-byte ASCII search would miss the marker.
    guard let inspected = String(data: xml, encoding: encoding), !inspected.contains("<!DOCTYPE"), !inspected.contains("<!ENTITY") else { try fail("invalidInput") }
    let parser = XMLParser(data: xml)
    let reader = DocumentTextReader()
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = reader
    let parsed = parser.parse()
    if let failure = reader.failure { try fail(failure) }
    guard parsed, reader.sawDocument else { try fail("invalidInput") }
    return try checkedText(reader.text)
}

func documentText(_ url: URL, ext: String, warnings: inout [String]) throws -> String {
    if ext == "pdf" {
        guard let document = PDFDocument(url: url) else { try fail("invalidInput") }
        guard !document.isLocked else { try fail("passwordProtected") }
        guard document.pageCount > 0 else { try fail("invalidInput") }
        guard document.pageCount <= pageLimit else { try fail("tooManyPages") }
        var paragraphs: [String] = []
        var length = 0
        var missing = false
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing = true }
            length += text.utf16.count + (index == 0 ? 0 : 2)
            guard length <= textLimit else { try fail("textTooLong") }
            paragraphs.append(text)
        }
        let text = paragraphs.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { try fail("noEmbeddedText") }
        if missing { warnings.append("somePagesWithoutText") }
        return text
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    if ext == "docx" {
        return try docxText(data)
    }
    if ext == "md" { warnings.append("markdownLiteral") }
    return try decodedText(data)
}

func textPDF(_ text: String) throws -> Data {
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData) else { try fail("conversionFailed") }
    var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { try fail("conversionFailed") }
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    style.paragraphSpacing = 6
    let content = text.isEmpty ? " " : text
    let attributed = NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style, .foregroundColor: NSColor.black])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CGPath(rect: page.insetBy(dx: 44, dy: 44), transform: nil)
    var position = 0
    var pages = 0
    while position < attributed.length {
        guard pages < pageLimit else { context.closePDF(); try fail("tooManyPages") }
        let layout = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), frame, nil)
        let range = CTFrameGetVisibleStringRange(layout)
        guard range.length > 0 else { context.closePDF(); try fail("conversionFailed") }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(page)
        CTFrameDraw(layout, context)
        context.endPDFPage()
        position += range.length
        pages += 1
    }
    context.closePDF()
    return output as Data
}

func xmlText(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        if scalar.value != 9 && scalar.value != 10 && scalar.value != 13 && scalar.value < 32 { continue }
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result
}

// Minimal standard DOCX: stored ZIP entries avoid extra executables/libraries.
func docxData(_ text: String) throws -> Data {
    guard text.unicodeScalars.allSatisfy({ scalar in
        scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (scalar.value >= 32 && scalar.value != 0xfffe && scalar.value != 0xffff)
    }) else { try fail("invalidInput") }
    let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let runs = line.split(separator: "\t", omittingEmptySubsequences: false).map { "<w:t xml:space=\"preserve\">\(xmlText(String($0)))</w:t>" }.joined(separator: "<w:tab/>")
        return "<w:p><w:r>\(runs)</w:r></w:p>"
    }.joined()
    let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"880\" w:right=\"880\" w:bottom=\"880\" w:left=\"880\"/></w:sectPr></w:body></w:document>"
    let files = [
        ("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
        ("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
        ("word/document.xml", document)
    ]
    var archive = Data(), central = Data()
    func append16(_ number: Int, to data: inout Data) { data.append(UInt8(number & 255)); data.append(UInt8((number >> 8) & 255)) }
    func append32(_ number: Int, to data: inout Data) { append16(number & 0xffff, to: &data); append16((number >> 16) & 0xffff, to: &data) }
    func crc32(_ bytes: Data) -> Int {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return Int(crc ^ 0xffffffff)
    }
    for (name, content) in files {
        let path = Data(name.utf8), bytes = Data(content.utf8), crc = crc32(bytes), offset = archive.count
        append32(0x04034b50, to: &archive)
        for number in [20, 0, 0, 0, 33] { append16(number, to: &archive) }
        for number in [crc, bytes.count, bytes.count] { append32(number, to: &archive) }
        append16(path.count, to: &archive); append16(0, to: &archive)
        archive.append(path); archive.append(bytes)
        append32(0x02014b50, to: &central)
        for number in [20, 20, 0, 0, 0, 33] { append16(number, to: &central) }
        for number in [crc, bytes.count, bytes.count] { append32(number, to: &central) }
        for number in [path.count, 0, 0, 0, 0] { append16(number, to: &central) }
        append32(0, to: &central); append32(offset, to: &central); central.append(path)
    }
    let centralOffset = archive.count
    archive.append(central)
    append32(0x06054b50, to: &archive)
    for number in [0, 0, files.count, files.count] { append16(number, to: &archive) }
    append32(central.count, to: &archive); append32(centralOffset, to: &archive); append16(0, to: &archive)
    return archive
}

func richTextData(_ text: String) -> Data {
    var result = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 "
    for unit in text.utf16 {
        switch unit {
        case 10: result += "\\par\n"
        case 13: continue
        case 9: result += "\\tab "
        case 92: result += "\\\\"
        case 123: result += "\\{"
        case 125: result += "\\}"
        case 32...126: result.unicodeScalars.append(UnicodeScalar(unit)!)
        default: result += "\\u\(Int16(bitPattern: unit))?"
        }
    }
    result += "}"
    return Data(result.utf8)
}

func htmlData(_ text: String) -> Data {
    let body = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    return Data("<!doctype html>\n<html lang=\"und\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>Converted document</title><style>body{max-width:54rem;margin:3rem auto;padding:0 1.5rem;font:16px/1.7 system-ui,sans-serif}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}</style></head><body><pre>\(body)</pre></body></html>\n".utf8)
}

func validatedRows(_ rows: [[String]]) throws -> [[String]] {
    guard let first = rows.first, !first.isEmpty, rows.allSatisfy({ $0.count == first.count }) else { try fail("invalidTable") }
    guard rows.count <= cellLimit, first.count <= cellLimit / rows.count else { try fail("tooManyCells") }
    var length = 0
    for row in rows {
        for cell in row {
            guard !cell.contains("\0") else { try fail("invalidTable") }
            length += cell.utf16.count
            guard length <= textLimit else { try fail("textTooLong") }
        }
    }
    return rows
}

func delimitedRows(_ text: String, separator: Character) throws -> [[String]] {
    guard !text.isEmpty else { try fail("invalidTable") }
    enum State { case start, unquoted, quoted, afterQuote }
    var state = State.start
    var rows: [[String]] = [], row: [String] = [], cell = ""
    var count = 0
    func finishCell() throws {
        count += 1
        guard count <= cellLimit else { try fail("tooManyCells") }
        row.append(cell); cell = ""; state = .start
    }
    func finishRow() throws { try finishCell(); rows.append(row); row = [] }
    for character in text {
        switch state {
        case .quoted:
            if character == "\"" { state = .afterQuote } else { cell.append(character) }
        case .afterQuote:
            if character == "\"" { cell.append(character); state = .quoted }
            else if character == separator { try finishCell() }
            else if character == "\n" { try finishRow() }
            else { try fail("invalidTable") }
        case .start, .unquoted:
            if character == "\"" {
                guard state == .start else { try fail("invalidTable") }
                state = .quoted
            } else if character == separator { try finishCell() }
            else if character == "\n" { try finishRow() }
            else { cell.append(character); state = .unquoted }
        }
    }
    guard state != .quoted else { try fail("invalidTable") }
    if !row.isEmpty || !cell.isEmpty || state != .start || !text.hasSuffix("\n") { try finishRow() }
    return try validatedRows(rows)
}

func tableOutput(_ url: URL, ext: String, format: String, warnings: inout [String]) throws -> Data {
    let text = try decodedText(Data(contentsOf: url, options: .mappedIfSafe))
    let rows: [[String]]
    if ext == "json" {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        catch { try fail("invalidTable") }
        guard let array = object as? [[String]] else { try fail("unsupportedJSONShape") }
        rows = try validatedRows(array)
    } else { rows = try delimitedRows(text, separator: ext == "csv" ? "," : "\t") }
    if format == "json" { return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes]) }
    let separator: Character = format == "csv" ? "," : "\t"
    var formulaLike = false
    let result = rows.map { row in row.map { cell -> String in
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, "=+-@".contains(first), trimmed.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) == nil { formulaLike = true }
        if cell.isEmpty || cell.contains(separator) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") { return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return cell
    }.joined(separator: String(separator)) }.joined(separator: "\n") + "\n"
    if formulaLike { warnings.append("spreadsheetFormulaLike") }
    return Data(result.utf8)
}

func loadImage(_ url: URL, warnings: inout [String]) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), let type = CGImageSourceGetType(source) else { try fail("invalidInput") }
    let allowed: Set<String> = ["public.png", "public.jpeg", "org.webmproject.webp", "public.heic", "public.heif", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif"]
    guard allowed.contains(type as String), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { try fail("invalidInput") }
    guard width <= pixelLimit, height <= pixelLimit, width <= pixelLimit / height else { try fail("imageTooLarge") }
    if CGImageSourceGetCount(source) > 1 { warnings.append("firstImageOnly") }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { try fail("invalidInput") }
    return image
}

func encodeImage(_ original: CGImage, format: String, warnings: inout [String]) throws -> Data {
    var image = original
    let hasAlpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
    if format == "pdf" {
        if hasAlpha { warnings.append("alphaFlattened") }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { try fail("conversionFailed") }
        let ratio = min(1, 1440 / CGFloat(max(image.width, image.height)))
        var bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { try fail("conversionFailed") }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.draw(image, in: bounds)
        context.endPDFPage(); context.closePDF()
        return output as Data
    }
    guard let type = imageDestinationTypes[format] else { try fail("unsupportedConversion") }
    let available = CGImageDestinationCopyTypeIdentifiers() as! [String]
    guard available.contains(type) else { try fail("encoderUnavailable") }
    if format == "gif" { warnings.append("gifPaletteLimited") }
    if ["jpg", "heic", "bmp", "gif"].contains(format) {
        if hasAlpha { warnings.append("alphaFlattened") }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { try fail("conversionFailed") }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { try fail("conversionFailed") }
        image = flattened
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else { try fail("encoderUnavailable") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.90, kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { try fail("conversionFailed") }
    return output as Data
}

func imageOutput(_ url: URL, format: String, warnings: inout [String]) throws -> Data {
    try encodeImage(loadImage(url, warnings: &warnings), format: format, warnings: &warnings)
}

func pdfImageOutput(_ url: URL, format: String, warnings: inout [String]) throws -> Data {
    guard let document = CGPDFDocument(url as CFURL) else { try fail("invalidInput") }
    guard document.isUnlocked else { try fail("passwordProtected") }
    guard document.numberOfPages > 0, let page = document.page(at: 1) else { try fail("invalidInput") }
    guard document.numberOfPages <= pageLimit else { try fail("tooManyPages") }
    let box = page.getBoxRect(.cropBox)
    let rotated = abs(page.rotationAngle) % 180 != 0
    let width = ceil((rotated ? box.height : box.width) * 2)
    let height = ceil((rotated ? box.width : box.height) * 2)
    guard width.isFinite, height.isFinite, width > 0, height > 0, width <= CGFloat(pixelLimit), height <= CGFloat(pixelLimit), width * height <= CGFloat(pixelLimit) else { try fail("imageTooLarge") }
    guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { try fail("conversionFailed") }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    guard let image = context.makeImage() else { try fail("conversionFailed") }
    warnings.append("firstPageOnly")
    return try encodeImage(image, format: format, warnings: &warnings)
}

func convert(_ request: Request) throws -> Reply {
    guard request.input.hasPrefix("/"), request.output.hasPrefix("/"), !request.input.contains("\0"), !request.output.contains("\0") else { try fail("invalidPath") }
    let input = URL(fileURLWithPath: request.input), output = URL(fileURLWithPath: request.output)
    guard input.standardizedFileURL != output.standardizedFileURL, !FileManager.default.fileExists(atPath: output.path) else { try fail("outputExists") }
    let ext = input.pathExtension.lowercased()
    let image = imageExtensions.contains(ext)
    let table = tableFormats.contains(ext)
    guard image || documentExtensions.contains(ext) || table else { try fail("unsupportedInput") }
    let formats: Set<String> = table ? tableFormats : image ? Set(imageDestinationTypes.keys).union(["pdf"]) : ext == "pdf" ? documentOutputFormats.subtracting(["pdf"]).union(["png", "jpg"]) : documentOutputFormats
    guard formats.contains(request.format) else { try fail("unsupportedConversion") }
    let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize else { try fail("invalidInput") }
    guard size <= (image ? imageLimit : documentLimit) else { try fail("inputTooLarge") }
    var warnings: [String] = []
    let data: Data
    if table { data = try tableOutput(input, ext: ext, format: request.format, warnings: &warnings) }
    else if image { data = try imageOutput(input, format: request.format, warnings: &warnings) }
    else if ext == "pdf" && ["png", "jpg"].contains(request.format) { data = try pdfImageOutput(input, format: request.format, warnings: &warnings) }
    else {
        let text = try documentText(input, ext: ext, warnings: &warnings)
        if request.format != "txt" || ext == "docx" { warnings.append("simpleReflow") }
        if ext == "pdf" { warnings.append("pdfTextReflow") }
        switch request.format {
        case "txt", "md": data = Data(text.utf8)
        case "pdf": data = try textPDF(text)
        case "docx": data = try docxData(text)
        case "rtf": data = richTextData(text)
        case "html": data = htmlData(text)
        default: try fail("unsupportedConversion")
        }
    }
    do { try data.write(to: output, options: .withoutOverwriting) }
    catch { try fail(FileManager.default.fileExists(atPath: output.path) ? "outputExists" : "writeFailed") }
    return Reply(ok: true, warning: warnings.isEmpty ? nil : warnings.joined(separator: ","))
}

let reply: Reply = autoreleasepool {
    do {
        let input = FileHandle.standardInput.readData(ofLength: 65_537)
        guard input.count <= 65_536 else { return Reply(ok: false, error: "invalidRequest") }
        let request = try JSONDecoder().decode(Request.self, from: input)
        return try convert(request)
    } catch let error as ConversionError { return Reply(ok: false, error: error.code) }
    catch {
        FileHandle.standardError.write(Data("Conversion failed: \(error.localizedDescription)\n".utf8))
        return Reply(ok: false, error: "invalidInput")
    }
}
let response = (try? JSONEncoder().encode(reply)) ?? Data("{\"ok\":false,\"error\":\"conversionFailed\"}".utf8)
FileHandle.standardOutput.write(response)
FileHandle.standardOutput.write(Data("\n".utf8))
exit(reply.ok ? 0 : 1)
