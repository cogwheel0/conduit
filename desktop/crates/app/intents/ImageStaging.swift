import AppIntents
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Send Image to Conduit's image, copied where the app takes it from: a
/// folder of its own under the temporary directory (this process's, which
/// the app reads as `std::env::temp_dir()`), one folder per image. The app
/// attaches it from there and clears old copies (crates/app/src/intents.rs).
///
/// Only an image of at most [maxBytes] is copied, as the phone stages it;
/// for anything else the app is told what it was, and says why it can't
/// take it in the user's language.
enum ImageStaging {
    /// The phone's limit.
    static let maxBytes = 20 * 1024 * 1024

    /// The folder's name under the temporary directory.
    static let folderName = "conduit-shortcuts-images"

    struct Staged {
        var path: String?
        var filename: String
        var isImage: Bool
        var byteCount: Int
    }

    static func stage(_ file: IntentFile) throws -> Staged {
        // Some providers leave the type out: the extension then decides.
        let name = (file.filename as NSString).lastPathComponent
        let type = file.type ?? UTType(filenameExtension: (name as NSString).pathExtension)
        let isImage = type?.conforms(to: .image) ?? false
        let byteCount: Int
        if let url = file.fileURL,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            byteCount = size
        } else {
            byteCount = file.data.count
        }
        guard isImage, byteCount > 0, byteCount <= maxBytes else {
            return Staged(path: nil, filename: name, isImage: isImage, byteCount: byteCount)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = stagedName(name, type: type)
        let target = folder.appendingPathComponent(safeName)
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: target)
        } else {
            try file.data.write(to: target, options: .atomic)
        }
        // A type or a name only says what the file claims to be (a renamed
        // file passes both): the copy must read as an image too.
        guard let detected = detectedImageType(target) else {
            try? FileManager.default.removeItem(at: folder)
            return Staged(path: nil, filename: name, isImage: false, byteCount: byteCount)
        }
        // Named as what it is: the app reads the kind (and the HEIC to JPEG
        // turn) from the name alone.
        let finalName = nameMatching(safeName, detected: detected)
        var staged = target
        if finalName != safeName {
            staged = folder.appendingPathComponent(finalName)
            try FileManager.default.moveItem(at: target, to: staged)
        }
        return Staged(path: staged.path, filename: finalName, isImage: true, byteCount: byteCount)
    }

    /// The picture type ImageIO reads the bytes at `url` as (a known image
    /// format with at least one image in it), or nil.
    static func detectedImageType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source) as String?
        else { return nil }
        return UTType(identifier) ?? .image
    }

    /// `name` with an extension that says `detected`: kept when its own
    /// already does (`.jpg` for a JPEG), else replaced by the type's own
    /// (`photo.txt` holding a PNG is `photo.png`).
    static func nameMatching(_ name: String, detected: UTType) -> String {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let own = UTType(filenameExtension: ext), own.conforms(to: detected) {
            return name
        }
        guard let wanted = detected.preferredFilenameExtension else { return name }
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Image" : stem
        return base + "." + wanted
    }

    /// The staged copy's name: the image's own, or "Image" when it has none,
    /// with the extension its type calls for when the name carries none (the
    /// app reads an attachment's kind, and turns a HEIC into a JPEG, from its
    /// name alone).
    static func stagedName(_ name: String, type: UTType?) -> String {
        let base = name.isEmpty || name.hasPrefix(".") ? "Image" : name
        guard (base as NSString).pathExtension.isEmpty,
            let ext = type?.preferredFilenameExtension
        else {
            return base
        }
        return "\(base).\(ext)"
    }
}
