import Foundation
import AppKit
import ImageIO
import PDFKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
import AVFoundation
import zlib

// A one-request process: no clipboard, preferences, network, or persistent cache.
struct GIFOptions: Decodable {
    let maxDimension: Int?
    let fps: Int?
    let loop: Bool?
    enum CodingKeys: String, CodingKey { case maxDimension, fps, loop }
    init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            maxDimension = try values.decodeIfPresent(Int.self, forKey: .maxDimension)
            fps = try values.decodeIfPresent(Int.self, forKey: .fps)
            loop = try values.decodeIfPresent(Bool.self, forKey: .loop)
        } catch { throw ConversionError(code: "invalidGifOptions") }
    }
}
struct Request: Decodable { let input: String; let output: String; let format: String; let gifOptions: GIFOptions? }
struct Reply: Encodable { let ok: Bool; var error: String?; var warning: String? }
struct ConversionError: Error { let code: String }
func fail(_ code: String) throws -> Never { throw ConversionError(code: code) }

let documentLimit = 20 * 1024 * 1024
let imageLimit = 50 * 1024 * 1024
let videoLimit = 100 * 1024 * 1024
let textLimit = 200_000
let pixelLimit = 40_000_000
let pageLimit = 100
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]
let videoExtensions: Set<String> = ["mov", "mp4"]
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
    let bytes = [UInt8](data.prefix(2))
    let text: String?
    if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
        guard data.count % 2 == 0 else { try fail("invalidEncoding") }
        let littleEndian = bytes[0] == 0xFF
        let units: [UInt16] = stride(from: 2, to: data.count, by: 2).map { offset in
            let first = UInt16(data[offset]), second = UInt16(data[offset + 1])
            return littleEndian ? first | (second << 8) : (first << 8) | second
        }
        // Foundation repairs invalid surrogate sequences on some macOS versions.
        // A code-unit round trip rejects any repair, including on macOS 13/14.
        let decoded = String(decoding: units, as: UTF16.self)
        guard decoded.utf16.elementsEqual(units) else { try fail("invalidEncoding") }
        text = decoded
    } else {
        let decoded = String(decoding: data, as: UTF8.self)
        guard decoded.utf8.elementsEqual(data) else { try fail("invalidEncoding") }
        text = decoded
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

struct DOCXImage {
    let data: Data
    let width: CGFloat
    let height: CGFloat
}

func textParagraphs(_ text: String) throws -> String {
    guard text.unicodeScalars.allSatisfy({ scalar in
        scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (scalar.value >= 32 && scalar.value != 0xfffe && scalar.value != 0xffff)
    }) else { try fail("invalidInput") }
    return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let runs = line.split(separator: "\t", omittingEmptySubsequences: false).map { "<w:t xml:space=\"preserve\">\(xmlText(String($0)))</w:t>" }.joined(separator: "<w:tab/>")
        return "<w:p><w:r>\(runs)</w:r></w:p>"
    }.joined()
}

func imageParagraph(_ image: DOCXImage, index: Int) -> String {
    let scale = min(1, min(507 / image.width, 700 / image.height))
    let width = max(1, Int((image.width * scale * 12_700).rounded()))
    let height = max(1, Int((image.height * scale * 12_700).rounded()))
    return "<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:docPr id=\"\(index)\" name=\"PDF image \(index)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(index)\" name=\"image\(index).png\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rIdImage\(index)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
}

// Standard DOCX package. Binary PNG entries use system zlib's fast CRC32.
func docxArchive(body: String, images: [DOCXImage] = []) throws -> Data {
    let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"880\" w:right=\"880\" w:bottom=\"880\" w:left=\"880\"/></w:sectPr></w:body></w:document>"
    let imageType = images.isEmpty ? "" : "<Default Extension=\"png\" ContentType=\"image/png\"/>"
    var files: [(String, Data)] = [
        ("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(imageType)<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8)),
        ("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)),
        ("word/document.xml", Data(document.utf8))
    ]
    if !images.isEmpty {
        let relationships = images.indices.map { "<Relationship Id=\"rIdImage\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\($0 + 1).png\"/>" }.joined()
        files.append(("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>".utf8)))
        for (index, image) in images.enumerated() { files.append(("word/media/image\(index + 1).png", image.data)) }
    }
    guard files.reduce(0, { $0 + $1.1.count }) <= 40 * 1024 * 1024 else { try fail("pdfImageLimit") }
    var archive = Data(), central = Data()
    func append16(_ number: Int, to data: inout Data) { data.append(UInt8(number & 255)); data.append(UInt8((number >> 8) & 255)) }
    func append32(_ number: Int, to data: inout Data) { append16(number & 0xffff, to: &data); append16((number >> 16) & 0xffff, to: &data) }
    for (name, bytes) in files {
        let path = Data(name.utf8), offset = archive.count
        let crc = bytes.withUnsafeBytes { Int(crc32(0, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt($0.count))) }
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

func docxData(_ text: String) throws -> Data { try docxArchive(body: textParagraphs(text)) }

struct PDFGraphicsState {
    var matrix = CGAffineTransform.identity
    var clip: CGRect
    var whiteFill = false
    var fillComponents = 1
}
final class PDFScanState {
    var graphics: PDFGraphicsState
    var stack: [PDFGraphicsState] = []
    var path = CGRect.null
    var boxes: [CGRect] = []
    var fallback = false
    var limitExceeded = false
    var invalidGeometry = false
    var depth: Int
    var operators = 0
    let pageRect: CGRect
    init(pageRect: CGRect, graphics: PDFGraphicsState? = nil, depth: Int = 0) {
        self.pageRect = pageRect; self.graphics = graphics ?? PDFGraphicsState(clip: pageRect); self.depth = depth
    }
    func tick(_ scanner: CGPDFScannerRef) -> Bool {
        operators += 1
        if operators > 200_000 || boxes.count > 500 || stack.count > 256 { limitExceeded = true; CGPDFScannerStop(scanner); return false }
        return true
    }
}
func pdfScanState(_ info: UnsafeMutableRawPointer?) -> PDFScanState { Unmanaged<PDFScanState>.fromOpaque(info!).takeUnretainedValue() }
func finitePDFTransform(_ matrix: CGAffineTransform) -> Bool { [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy { $0.isFinite } }
func finitePDFRect(_ rect: CGRect) -> Bool { [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy { $0.isFinite } }
func pdfNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGPDFReal](repeating: 0, count: count)
    for index in stride(from: count - 1, through: 0, by: -1) { guard CGPDFScannerPopNumber(scanner, &values[index]), values[index].isFinite else { return nil } }
    return values
}
func pdfArrayRect(_ dictionary: CGPDFDictionaryRef, key: String) -> CGRect? {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
    var values = [CGPDFReal](repeating: 0, count: 4)
    for index in 0..<4 { guard CGPDFArrayGetNumber(array, index, &values[index]), values[index].isFinite else { return nil } }
    let rect = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1]).standardized
    return finitePDFRect(rect) ? rect : nil
}
func pdfPathPoints(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, count: Int) {
    let state = pdfScanState(info)
    guard state.tick(scanner), let values = pdfNumbers(scanner, count) else { state.fallback = true; return }
    for index in stride(from: 0, to: count, by: 2) {
        let point = CGPoint(x: values[index], y: values[index + 1]).applying(state.graphics.matrix)
        state.path = state.path.union(CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001))
    }
}
func pdfPathPaint(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, stroke: Bool) {
    let state = pdfScanState(info)
    guard state.tick(scanner) else { return }
    // A plain white page background does not need to become an image block.
    let background = state.graphics.whiteFill && !stroke && state.path.insetBy(dx: -1, dy: -1).contains(state.pageRect)
    if !state.path.isNull && !background { state.fallback = true }
    state.path = .null
}
func scanPDFContent(_ content: CGPDFContentStreamRef, state: PDFScanState) -> Bool {
    guard state.depth < 16 else { state.limitExceeded = true; return false }
    let table = CGPDFOperatorTableCreate()!
    defer { CGPDFOperatorTableRelease(table) }
    CGPDFOperatorTableSetCallback(table, "q") { scanner, info in let s = pdfScanState(info); if s.tick(scanner) { s.stack.append(s.graphics) } }
    CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in let s = pdfScanState(info); if s.tick(scanner), let saved = s.stack.popLast() { s.graphics = saved } }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
        let s = pdfScanState(info)
        guard s.tick(scanner), let v = pdfNumbers(scanner, 6) else { s.fallback = true; return }
        s.graphics.matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.graphics.matrix)
        if !finitePDFTransform(s.graphics.matrix) { s.invalidGeometry = true; CGPDFScannerStop(scanner) }
    }
    CGPDFOperatorTableSetCallback(table, "g") { scanner, info in let s = pdfScanState(info); s.graphics.whiteFill = (pdfNumbers(scanner, 1)?.first ?? 0) >= 0.999 }
    CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in let s = pdfScanState(info); s.graphics.whiteFill = pdfNumbers(scanner, 3)?.allSatisfy { $0 >= 0.999 } ?? false }
    CGPDFOperatorTableSetCallback(table, "k") { scanner, info in let s = pdfScanState(info); s.graphics.whiteFill = pdfNumbers(scanner, 4)?.allSatisfy { $0 <= 0.001 } ?? false }
    CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
        let s = pdfScanState(info)
        guard s.tick(scanner) else { return }
        s.graphics.whiteFill = false; s.graphics.fillComponents = 0
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { s.fallback = true; return }
        switch String(cString: name) {
        case "DeviceGray": s.graphics.fillComponents = 1
        case "DeviceRGB": s.graphics.fillComponents = 3
        case "DeviceCMYK": s.graphics.fillComponents = 4
        case "Pattern": s.graphics.fillComponents = -1
        default:
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "ColorSpace", name) else { return }
            var array: CGPDFArrayRef?, kind: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetName(array, 0, &kind), let kind else { return }
            switch String(cString: kind) {
            case "CalGray": s.graphics.fillComponents = 1
            case "CalRGB": s.graphics.fillComponents = 3
            case "Pattern": s.graphics.fillComponents = -1
            case "ICCBased":
                var profile: CGPDFStreamRef?, count = 0
                if CGPDFArrayGetStream(array, 1, &profile), let profile, let dictionary = CGPDFStreamGetDictionary(profile), CGPDFDictionaryGetInteger(dictionary, "N", &count), [1, 3, 4].contains(count) { s.graphics.fillComponents = count }
            default: break
            }
        }
    }
    for op in ["sc", "scn"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in
        let s = pdfScanState(info)
        guard s.tick(scanner) else { return }
        s.graphics.whiteFill = false
        if s.graphics.fillComponents == -1 { s.fallback = true; return }
        if s.graphics.fillComponents > 0, let values = pdfNumbers(scanner, s.graphics.fillComponents) {
            s.graphics.whiteFill = s.graphics.fillComponents == 4 ? values.allSatisfy { $0 <= 0.001 } : values.allSatisfy { $0 >= 0.999 }
        }
    } }
    CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
        let s = pdfScanState(info)
        guard s.tick(scanner), let v = pdfNumbers(scanner, 4) else { s.fallback = true; return }
        s.path = s.path.union(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).applying(s.graphics.matrix).standardized)
    }
    for op in ["m", "l"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in pdfPathPoints(scanner, info, count: 2) } }
    CGPDFOperatorTableSetCallback(table, "c") { scanner, info in pdfPathPoints(scanner, info, count: 6) }
    for op in ["v", "y"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in pdfPathPoints(scanner, info, count: 4) } }
    for op in ["f", "F", "f*"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in pdfPathPaint(scanner, info, stroke: false) } }
    for op in ["S", "s", "B", "B*", "b", "b*"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in pdfPathPaint(scanner, info, stroke: true) } }
    for op in ["W", "W*"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in
        let s = pdfScanState(info); _ = s.tick(scanner)
        if !s.path.isNull { s.graphics.clip = s.graphics.clip.intersection(s.path) }
    } }
    CGPDFOperatorTableSetCallback(table, "n") { _, info in pdfScanState(info).path = .null }
    // Inline images, shadings and pattern fills are preserved as a whole page.
    for op in ["BI", "ID", "EI", "sh"] { CGPDFOperatorTableSetCallback(table, op) { scanner, info in let s = pdfScanState(info); _ = s.tick(scanner); s.fallback = true } }
    for op in ["BT", "ET", "Tj", "TJ", "'", "\"", "Tm", "Td", "TD", "T*", "Tf", "Tc", "Tw", "Tz", "TL", "Tr", "Ts", "gs", "CS", "SC", "SCN", "G", "RG", "K", "w", "J", "j", "M", "d", "ri", "i", "h", "BMC", "BDC", "EMC", "MP", "DP"] {
        CGPDFOperatorTableSetCallback(table, op) { scanner, info in _ = pdfScanState(info).tick(scanner) }
    }
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
        let s = pdfScanState(info)
        guard s.tick(scanner) else { return }
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { s.fallback = true; return }
        let parent = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { s.fallback = true; return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { s.fallback = true; return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { s.fallback = true; return }
        switch String(cString: subtype) {
        case "Image":
            let transformed = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.graphics.matrix).standardized
            guard finitePDFRect(transformed) else { s.invalidGeometry = true; CGPDFScannerStop(scanner); return }
            let rect = transformed.intersection(s.graphics.clip)
            if !rect.isNull && rect.width > 0 && rect.height > 0 { s.boxes.append(rect) }
        case "Form":
            guard s.depth < 15 else { s.limitExceeded = true; CGPDFScannerStop(scanner); return }
            var graphics = s.graphics
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
                guard CGPDFArrayGetCount(array) == 6 else { s.invalidGeometry = true; CGPDFScannerStop(scanner); return }
                var v = [CGPDFReal](repeating: 0, count: 6)
                for index in 0..<6 { guard CGPDFArrayGetNumber(array, index, &v[index]), v[index].isFinite else { s.fallback = true; return } }
                graphics.matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(graphics.matrix)
                guard finitePDFTransform(graphics.matrix) else { s.invalidGeometry = true; CGPDFScannerStop(scanner); return }
            }
            guard let bounds = pdfArrayRect(dictionary, key: "BBox"), finitePDFRect(bounds.applying(graphics.matrix)) else { s.invalidGeometry = true; CGPDFScannerStop(scanner); return }
            graphics.clip = graphics.clip.intersection(bounds.applying(graphics.matrix))
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let child = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
            defer { CGPDFContentStreamRelease(child) }
            let childState = PDFScanState(pageRect: s.pageRect, graphics: graphics, depth: s.depth + 1)
            if !scanPDFContent(child, state: childState) { s.fallback = true }
            s.fallback = s.fallback || childState.fallback
            s.boxes.append(contentsOf: childState.boxes); s.operators += childState.operators
            s.limitExceeded = s.limitExceeded || childState.limitExceeded
            s.invalidGeometry = s.invalidGeometry || childState.invalidGeometry
            if s.limitExceeded || s.invalidGeometry || !s.tick(scanner) { CGPDFScannerStop(scanner) }
        default: s.fallback = true
        }
    }
    let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
    defer { CGPDFScannerRelease(scanner) }
    let success = CGPDFScannerScan(scanner)
    return success && !state.fallback
}

struct PDFRaster { let image: CGImage; let transform: CGAffineTransform; let bounds: CGRect }
func renderPDFPage(_ page: CGPDFPage, totalPixels: inout Int) throws -> PDFRaster {
    let crop = page.getBoxRect(.cropBox)
    let rotated = abs(page.rotationAngle) % 180 != 0
    let width = ceil((rotated ? crop.height : crop.width) * 2), height = ceil((rotated ? crop.width : crop.height) * 2)
    guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= CGFloat(pixelLimit) else { try fail("pdfImageLimit") }
    totalPixels += Int(width * height)
    guard totalPixels <= 200_000_000 else { try fail("pdfImageLimit") }
    guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { try fail("conversionFailed") }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    // CoreGraphics may decline to upscale a PDF in getDrawingTransform. Apply
    // the 2x raster scale explicitly so PNG pixels and Word point sizes agree.
    let pointBounds = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
    let transform = page.getDrawingTransform(.cropBox, rect: pointBounds, rotate: 0, preserveAspectRatio: true).concatenating(CGAffineTransform(scaleX: 2, y: 2))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    context.concatenate(transform); context.drawPDFPage(page)
    guard let image = context.makeImage() else { try fail("conversionFailed") }
    return PDFRaster(image: image, transform: transform, bounds: bounds)
}
func pdfCroppedImage(_ raster: PDFRaster, rect: CGRect) throws -> DOCXImage {
    let transformed = rect.applying(raster.transform).standardized.intersection(raster.bounds)
    // CGImage crops count rows from the top; PDF user-space Y increases upward.
    let crop = CGRect(x: transformed.minX, y: raster.bounds.height - transformed.maxY, width: transformed.width, height: transformed.height).integral.intersection(raster.bounds)
    guard !crop.isNull, crop.width >= 1, crop.height >= 1, let image = raster.image.cropping(to: crop) else { try fail("conversionFailed") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { try fail("conversionFailed") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { try fail("conversionFailed") }
    return DOCXImage(data: output as Data, width: crop.width / 2, height: crop.height / 2)
}
func mergedImageRects(_ input: [CGRect]) -> [CGRect] {
    var output: [CGRect] = []
    for original in input {
        var rect = original
        var index = 0
        while index < output.count {
            if rect.intersects(output[index]) { rect = rect.union(output.remove(at: index)); index = 0 }
            else { index += 1 }
        }
        output.append(rect)
    }
    return output
}
func mergedPDFTextLines(_ input: [(CGRect, String)]) -> [(CGRect, String)] {
    // PDFKit can split one baseline into several selections at font changes.
    // Group against a fixed row baseline, then join adjacent fragments in X order.
    let sorted = input.sorted { $0.0.midY == $1.0.midY ? $0.0.minX < $1.0.minX : $0.0.midY > $1.0.midY }
    var rows: [(baseline: CGFloat, height: CGFloat, fragments: [(CGRect, String)])] = []
    for item in sorted {
        if let index = rows.lastIndex(where: { abs($0.baseline - item.0.midY) <= max(2, min($0.height, item.0.height) * 0.3) }) {
            rows[index].fragments.append(item)
        } else { rows.append((item.0.midY, item.0.height, [item])) }
    }
    var output: [(CGRect, String)] = []
    for row in rows {
        for fragment in row.fragments.sorted(by: { $0.0.minX < $1.0.minX }) {
            if let last = output.last, abs(last.0.midY - row.baseline) <= max(2, row.height * 0.3), fragment.0.minX - last.0.maxX < max(18, row.height * 2) {
                let gap = fragment.0.minX - last.0.maxX
                let separator = gap > row.height * 0.2 && !last.1.hasSuffix(" ") && !fragment.1.hasPrefix(" ") ? " " : ""
                output[output.count - 1] = (last.0.union(fragment.0), last.1 + separator + fragment.1)
            } else { output.append(fragment) }
        }
    }
    return output
}
func pdfDOCXData(_ url: URL, warnings: inout [String]) throws -> Data {
    guard let pdf = CGPDFDocument(url as CFURL), let selectable = PDFDocument(url: url) else { try fail("invalidInput") }
    guard pdf.isUnlocked, !selectable.isLocked else { try fail("passwordProtected") }
    guard pdf.numberOfPages > 0 else { try fail("invalidInput") }
    guard pdf.numberOfPages <= pageLimit else { try fail("tooManyPages") }
    var body = "", images: [DOCXImage] = [], totalPixels = 0, totalBytes = 0, textLength = 0
    var fallbackUsed = false, textInImages = false
    for pageNumber in 1...pdf.numberOfPages {
        try autoreleasepool {
            guard let page = pdf.page(at: pageNumber), let textPage = selectable.page(at: pageNumber - 1) else { try fail("invalidInput") }
            let crop = page.getBoxRect(.cropBox)
            guard finitePDFRect(crop), crop.width > 0, crop.height > 0 else { try fail("invalidInput") }
            let state = PDFScanState(pageRect: crop)
            let content = CGPDFContentStreamCreateWithPage(page)
            defer { CGPDFContentStreamRelease(content) }
            let scanned = scanPDFContent(content, state: state)
            guard !state.limitExceeded else { try fail("pdfImageLimit") }
            guard !state.invalidGeometry else { try fail("invalidInput") }
            // Non-link annotation appearances are not part of the page stream.
            // Refuse rather than silently omit a stamp, signature or attached image.
            guard !textPage.annotations.contains(where: { $0.type != "Link" && $0.shouldDisplay }) else { try fail("pdfUnsupportedAnnotation") }
            let pageText = textPage.string ?? ""
            textLength += pageText.utf16.count
            guard textLength <= textLimit else { try fail("textTooLong") }
            let selections = textPage.selection(for: crop)?.selectionsByLine() ?? []
            var lines = selections.compactMap { selection -> (CGRect, String)? in
                guard let text = selection.string, !text.isEmpty else { return nil }
                let bounds = selection.bounds(for: textPage)
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0, bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite else { return nil }
                return (bounds, text)
            }
            var rects = mergedImageRects(state.boxes.map { $0.intersection(crop) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 })
            let visibleText = textPage.selection(for: crop)?.string ?? ""
            let covered = lines.map { $0.1 }.joined().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.sorted { $0.value < $1.value }
            let expected = visibleText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.sorted { $0.value < $1.value }
            let fallback = !scanned || covered != expected || (!pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lines.isEmpty)
            lines = mergedPDFTextLines(lines)
            if fallback {
                rects = [crop]; lines = []; fallbackUsed = true
            } else if rects.isEmpty && pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Empty/vector-only/scanned pages must remain present in Word.
                rects = [crop]; fallbackUsed = true
            }
            if !fallback && !rects.isEmpty {
                // A crop includes all visible paint inside it. Keep overlapping text
                // in that image instead of repeating it as an editable paragraph.
                var changed = true
                while changed {
                    changed = false
                    var retained: [(CGRect, String)] = []
                    for line in lines {
                        if let index = rects.firstIndex(where: { $0.intersects(line.0) }) {
                            rects[index] = rects[index].union(line.0).intersection(crop); textInImages = true; changed = true
                        } else { retained.append(line) }
                    }
                    lines = retained; rects = mergedImageRects(rects)
                }
            }
            if pageNumber > 1 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            let raster = rects.isEmpty ? nil : try renderPDFPage(page, totalPixels: &totalPixels)
            let ordering = page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: abs(page.rotationAngle) % 180 == 0 ? crop.width : crop.height, height: abs(page.rotationAngle) % 180 == 0 ? crop.height : crop.width), rotate: 0, preserveAspectRatio: true)
            let unsorted = lines.map { (rect: $0.0, text: Optional($0.1)) } + rects.map { (rect: $0, text: Optional<String>.none) }
            var blocks = unsorted.enumerated().map { (rect: $0.element.rect, text: $0.element.text, index: $0.offset) }
            blocks.sort { a, b in
                let first = a.rect.applying(ordering), second = b.rect.applying(ordering)
                let firstRow = (first.maxY / 3).rounded(), secondRow = (second.maxY / 3).rounded()
                if firstRow != secondRow { return firstRow > secondRow }
                if first.minX != second.minX { return first.minX < second.minX }
                return a.index < b.index
            }
            for block in blocks {
                if let text = block.text { body += try textParagraphs(text) }
                else if let raster {
                    guard images.count < 500 else { try fail("pdfImageLimit") }
                    let image = try pdfCroppedImage(raster, rect: block.rect)
                    totalBytes += image.data.count
                    guard totalBytes <= 40 * 1024 * 1024 else { try fail("pdfImageLimit") }
                    images.append(image); body += imageParagraph(image, index: images.count)
                }
            }
        }
    }
    warnings.append(images.isEmpty ? "pdfTextReflow" : "pdfImagesReflow")
    if fallbackUsed { warnings.append("pdfVisualFallback") }
    if textInImages { warnings.append("pdfTextInImages") }
    return try docxArchive(body: body, images: images)
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

final class GIFByteSink {
    var data = Data()
    var exceeded = false
    let limit = 50 * 1024 * 1024
}

// Load only metadata before decoding. External references in reference movies
// are forbidden, including local references outside the selected input file.
final class VideoMetadataResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
    func take() -> Result<T, Error> { lock.lock(); defer { lock.unlock() }; return result! }
}
func loadVideoMetadata<T>(_ action: @escaping @Sendable () async throws -> T) throws -> T {
    let ready = DispatchSemaphore(value: 0), box = VideoMetadataResult<T>()
    let task = Task.detached {
        do { box.store(.success(try await action())) }
        catch { box.store(.failure(error)) }
        ready.signal()
    }
    guard ready.wait(timeout: .now() + 15) == .success else { task.cancel(); try fail("videoMetadataTimeout") }
    do { return try box.take().get() }
    catch let error as ConversionError { throw error }
    catch { try fail("invalidVideo") }
}

func videoGIFOutput(_ url: URL, options: GIFOptions?, warnings: inout [String]) throws -> Data {
    let dimension = options?.maxDimension ?? 480, fps = options?.fps ?? 15, loop = options?.loop ?? true
    guard [320, 480, 640].contains(dimension), [10, 15, 20].contains(fps) else { try fail("invalidGifOptions") }
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true, AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    defer { asset.cancelLoading() }
    let metadata = try loadVideoMetadata {
        guard try await !asset.load(.hasProtectedContent) else { try fail("videoProtected") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { try fail("videoNoTrack") }
        guard try await asset.load(.isPlayable) else { try fail("invalidVideo") }
        return try await (asset.load(.duration), track.load(.naturalSize), track.load(.preferredTransform), !asset.loadTracks(withMediaType: .audio).isEmpty)
    }
    let duration = CMTimeGetSeconds(metadata.0)
    guard duration.isFinite, duration > 0 else { try fail("invalidVideo") }
    guard duration <= 15.000_001 else { try fail("videoTooLong") }
    guard duration >= 0.04 else { try fail("videoTooShort") }
    let natural = metadata.1, transform = metadata.2
    guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0, natural.width * natural.height <= CGFloat(pixelLimit), finitePDFTransform(transform) else { try fail("gifResourceLimit") }
    let display = CGRect(origin: .zero, size: natural).applying(transform).standardized
    guard finitePDFRect(display), display.width >= 1, display.height >= 1 else { try fail("invalidVideo") }
    let scale = min(1, CGFloat(dimension) / max(display.width, display.height))
    let width = max(1, Int((display.width * scale).rounded(.down))), height = max(1, Int((display.height * scale).rounded(.down)))
    let totalCentiseconds = Int((duration * 100).rounded())
    var frames = max(2, Int(ceil(duration * Double(fps) - 0.000_001)))
    // GIF timing has hundredth-second precision. Distribute rounding at frame
    // boundaries and fold a <20ms final remainder into the preceding frame.
    if frames > 2 && totalCentiseconds - Int((Double(frames - 1) * 100 / Double(fps)).rounded()) < 2 { frames -= 1 }
    guard frames <= 300, width * height <= 125_000_000 / frames else { try fail("gifResourceLimit") }
    var boundaries: [Int] = []
    let frameRate = Double(fps)
    let splitShortClip = frames == 2 && duration < 2.0 / frameRate
    for index in 0...frames {
        if index == frames {
            boundaries.append(totalCentiseconds)
        } else if splitShortClip {
            let boundary = Double(index) * Double(totalCentiseconds) / 2.0
            boundaries.append(Int(boundary.rounded()))
        } else {
            let boundary = Double(index) * 100.0 / frameRate
            boundaries.append(Int(boundary.rounded()))
        }
    }
    guard zip(boundaries, boundaries.dropFirst()).allSatisfy({ $1 > $0 }) else { try fail("videoTooShort") }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: width, height: height)
    // Exact requested times select the containing decoded frame without seeking
    // to an earlier keyframe; only the current CGImage is retained by our code.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    defer { generator.cancelAllCGImageGeneration() }
    let sink = GIFByteSink()
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
        guard let info else { return 0 }
        let sink = Unmanaged<GIFByteSink>.fromOpaque(info).takeUnretainedValue()
        guard count <= sink.limit - sink.data.count else { sink.exceeded = true; return 0 }
        sink.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }, releaseConsumer: { info in
        if let info { Unmanaged<GIFByteSink>.fromOpaque(info).release() }
    })
    let sinkInfo = Unmanaged.passRetained(sink).toOpaque()
    guard let consumer = CGDataConsumer(info: sinkInfo, cbks: &callbacks) else {
        Unmanaged<GIFByteSink>.fromOpaque(sinkInfo).release(); try fail("encoderUnavailable")
    }
    guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.gif.identifier as CFString, frames, nil) else { try fail("encoderUnavailable") }
    if loop { CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
    for index in 0..<frames {
        try autoreleasepool {
            let seconds = Double(boundaries[index]) / 100
            let original: CGImage
            do { original = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 60_000), actualTime: nil) }
            catch { try fail("videoDecodeFailed") }
            guard original.width * original.height <= pixelLimit else { try fail("gifResourceLimit") }
            // Normalize color/alpha and exact output dimensions after AVFoundation
            // applies orientation; no frame array or full-video data is allocated.
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { try fail("conversionFailed") }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            context.interpolationQuality = .high; context.draw(original, in: bounds)
            guard let frame = context.makeImage() else { try fail("conversionFailed") }
            let delay = Double(boundaries[index + 1] - boundaries[index]) / 100
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            guard !sink.exceeded else { try fail("gifResourceLimit") }
        }
    }
    let finished = CGImageDestinationFinalize(destination)
    guard !sink.exceeded else { try fail("gifResourceLimit") }
    guard finished, !sink.data.isEmpty else { try fail("conversionFailed") }
    warnings.append("animatedGifLossy")
    if metadata.3 { warnings.append("videoAudioRemoved") }
    return sink.data
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
    let video = videoExtensions.contains(ext)
    let table = tableFormats.contains(ext)
    guard image || video || documentExtensions.contains(ext) || table else { try fail("unsupportedInput") }
    let formats: Set<String> = video ? ["gif"] : table ? tableFormats : image ? Set(imageDestinationTypes.keys).union(["pdf"]) : ext == "pdf" ? documentOutputFormats.subtracting(["pdf"]).union(["png", "jpg"]) : documentOutputFormats
    guard formats.contains(request.format) else { try fail("unsupportedConversion") }
    let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize else { try fail("invalidInput") }
    guard size <= (video ? videoLimit : image ? imageLimit : documentLimit) else { try fail("inputTooLarge") }
    var warnings: [String] = []
    let data: Data
    if video { data = try videoGIFOutput(input, options: request.gifOptions, warnings: &warnings) }
    else if table { data = try tableOutput(input, ext: ext, format: request.format, warnings: &warnings) }
    else if image { data = try imageOutput(input, format: request.format, warnings: &warnings) }
    else if ext == "pdf" && ["png", "jpg"].contains(request.format) { data = try pdfImageOutput(input, format: request.format, warnings: &warnings) }
    else if ext == "pdf" && request.format == "docx" {
        data = try pdfDOCXData(input, warnings: &warnings)
    }
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
