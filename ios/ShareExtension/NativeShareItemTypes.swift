import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Picks the registered type whose representation holds the shared content.
///
/// Loading a generic supertype or a URL type makes NSItemProvider stage a
/// stand-in instead of the bytes: `public.file-url` writes a small "file URL"
/// property list that only holds the path. Prefer the sender's own content
/// type, in the order it registered them.
func nativeShareContentTypeIdentifier(
  registeredTypeIdentifiers: [String],
  conformingTo category: UTType
) -> String? {
  registeredTypeIdentifiers.first { identifier in
    guard let type = UTType(identifier) else { return false }
    return type.conforms(to: category)
      && type.conforms(to: .data)
      && !type.conforms(to: .url)
  }
}

/// Names a staged copy after the sender's file rather than the type.
///
/// NSItemProvider names file-representation copies after their type, such as
/// "PDF document.pdf". Keep the sender's name and make sure it still ends in
/// the extension of the bytes that were actually loaded.
func nativeShareSourceFileName(
  loadedName: String,
  preferredName: String?
) -> String {
  guard let preferredName = preferredName?
    .trimmingCharacters(in: .whitespacesAndNewlines),
    !preferredName.isEmpty
  else {
    return loadedName
  }
  let loadedExtension = (loadedName as NSString).pathExtension
  guard !loadedExtension.isEmpty else { return preferredName }
  let preferredExtension = (preferredName as NSString).pathExtension
  if !preferredExtension.isEmpty {
    if preferredExtension.caseInsensitiveCompare(loadedExtension)
      == .orderedSame {
      return preferredName
    }
    // "photo.jpg" already names JPEG bytes loaded as "JPEG image.jpeg".
    if let preferredType = UTType(filenameExtension: preferredExtension),
       let loadedType = UTType(filenameExtension: loadedExtension),
       !preferredType.isDynamic,
       preferredType == loadedType {
      return preferredName
    }
  }
  return "\(preferredName).\(loadedExtension)"
}

/// Whether a file representation holds an archived object, not content.
///
/// A `UIImage` registered under an image type, as the screenshot editor
/// shares one, has no file behind it. NSItemProvider writes a keyed archive
/// of the object instead, under a name like "PNG image.png". Only that
/// binary property list header counts: formats ImageIO cannot read, such as
/// SVG, are still the sender's real file.
func nativeShareFileIsArchivedObject(at url: URL) -> Bool {
  guard let handle = try? FileHandle(forReadingFrom: url) else {
    return false
  }
  defer { try? handle.close() }
  let header = (try? handle.read(upToCount: 8)) ?? Data()
  return header == Data("bplist00".utf8)
}

/// The image format ImageIO recognizes in the bytes, if any.
func nativeShareImageType(of data: Data) -> UTType? {
  // Reads only the container header; no pixels are decoded. ImageIO also
  // opens PDFs, which are not image attachments.
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetCount(source) > 0,
        let identifier = CGImageSourceGetType(source) as String?,
        let type = UTType(identifier),
        type.conforms(to: .image)
  else {
    return nil
  }
  return type
}

/// Encodes an in-memory shared image for upload.
///
/// JPEG keeps photos small when the sender declared JPEG. Everything else,
/// screenshots included, is written as lossless PNG.
func nativeShareEncodedImage(
  _ image: UIImage,
  typeIdentifier: String
) -> (data: Data, fileExtension: String)? {
  if UTType(typeIdentifier)?.conforms(to: .jpeg) == true {
    // JPEG data carries the orientation in its EXIF metadata.
    return image.jpegData(compressionQuality: 0.9).map { ($0, "jpg") }
  }
  var upright = image
  if image.imageOrientation != .up {
    // PNG data has no orientation, so draw the pixels upright first.
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    upright = UIGraphicsImageRenderer(size: image.size, format: format)
      .image { _ in image.draw(at: .zero) }
  }
  return upright.pngData().map { ($0, "png") }
}
