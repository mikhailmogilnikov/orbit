import AppKit
import OrbitACP
import OrbitAPI
import UniformTypeIdentifiers

/// Something sent to the agent along with the prompt text.
enum PromptAttachment: Identifiable, Hashable {
    case file(URL)
    case selection(EditorSelection)
    case image(Data, mimeType: String)

    var id: String {
        switch self {
        case .file(let url): "file:\(url.path)"
        case .selection(let selection): "selection:\(selection.url.path):\(selection.lines.lowerBound)-\(selection.lines.upperBound):\(selection.text.hashValue)"
        case .image(let data, _): "image:\(data.hashValue)"
        }
    }

    var label: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .selection(let selection):
            selection.lines.count == 1
                ? "\(selection.url.lastPathComponent):\(selection.lines.lowerBound)"
                : "\(selection.url.lastPathComponent):\(selection.lines.lowerBound)-\(selection.lines.upperBound)"
        case .image: "Image"
        }
    }

    var systemImage: String {
        switch self {
        case .file(let url): FileIcon.systemImage(for: url)
        case .selection: "text.cursor"
        case .image: "photo"
        }
    }

    /// Agents need images in a format they accept and under their size limits.
    static let maxImageBytes = 5 << 20

    /// A dropped or picked file: images become image attachments, anything else a file.
    static func from(fileURL url: URL) -> PromptAttachment {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let attachment = imageAttachment(contentsOf: url) {
            return attachment
        }
        return .file(url.standardizedFileURL)
    }

    static func imageAttachment(contentsOf url: URL) -> PromptAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, [UTType.png, .jpeg, .gif, .webP].contains(type), let mime = type.preferredMIMEType {
            return .image(data, mimeType: mime)
        }
        return imageAttachment(from: NSImage(data: data))
    }

    /// Other formats (TIFF from the pasteboard, HEIC…) are sent as PNG.
    static func imageAttachment(from image: NSImage?) -> PromptAttachment? {
        guard let image, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return .image(png, mimeType: "image/png")
    }
}

/// What the agent accepts in a prompt besides text and resource links.
struct PromptCapabilities: Equatable {
    var image = false
    var embeddedContext = false

    init() {}

    init(_ json: JSONValue?) {
        image = json?["image"]?.bool == true
        embeddedContext = json?["embeddedContext"]?.bool == true
    }
}

enum PromptBuilder {
    /// Files up to this size go in whole; bigger ones as links the agent can read.
    static let maxEmbeddedFileBytes = 200_000

    /// ACP content blocks: the text, then each attachment. `contents` gives a
    /// file's current text (open buffers included, so unsaved edits count).
    @MainActor
    static func content(
        text: String,
        attachments: [PromptAttachment],
        capabilities: PromptCapabilities,
        contents: (URL) -> String?
    ) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        for attachment in attachments {
            switch attachment {
            case .file(let url):
                let uri = url.absoluteString
                if capabilities.embeddedContext, let text = contents(url), text.utf8.count <= maxEmbeddedFileBytes {
                    blocks.append(["type": "resource", "resource": ["uri": .string(uri), "mimeType": "text/plain", "text": .string(text)]])
                } else {
                    blocks.append(["type": "resource_link", "uri": .string(uri), "name": .string(url.lastPathComponent)])
                }
            case .selection(let selection):
                let uri = "\(selection.url.absoluteString)#L\(selection.lines.lowerBound)-L\(selection.lines.upperBound)"
                if capabilities.embeddedContext {
                    blocks.append(["type": "resource", "resource": ["uri": .string(uri), "mimeType": "text/plain", "text": .string(selection.text)]])
                } else {
                    let fence = selection.text.contains("```") ? "````" : "```"
                    let header = "\(selection.url.path) lines \(selection.lines.lowerBound)-\(selection.lines.upperBound)"
                    blocks.append(["type": "text", "text": .string("\(header):\n\(fence)\n\(selection.text)\n\(fence)")])
                }
            case .image(let data, let mimeType):
                guard capabilities.image else { continue }
                blocks.append(["type": "image", "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())])
            }
        }
        return blocks
    }
}
