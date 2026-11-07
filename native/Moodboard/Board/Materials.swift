import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pictures and films added by hand. The file is copied in, so the wall keeps working if the original moves.
enum MaterialStore {
  struct Unreadable: LocalizedError {
    let name: String
    var errorDescription: String? { "\(name) isn't an image or a video." }
  }

  static func add(_ url: URL) async throws -> (id: String, material: Material) {
    let type = UTType(filenameExtension: url.pathExtension)
    let title = url.deletingPathExtension().lastPathComponent
    let name = UUID().uuidString.lowercased() + "." + url.pathExtension.lowercased()
    let target = Paths.materials.appending(path: name)
    let id = "material/" + name

    if type?.conforms(to: .image) == true, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
      try FileManager.default.copyItem(at: url, to: target)
      return (id, Material(kind: .image, src: name, title: title, w: Double(image.width), h: Double(image.height), bare: isCutOut(image) ? true : nil))
    }
    if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
      let asset = AVURLAsset(url: url)
      guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Unreadable(name: url.lastPathComponent) }
      let size = try await track.load(.naturalSize)
      try FileManager.default.copyItem(at: url, to: target)
      return (id, Material(kind: .video, src: name, title: title, w: abs(size.width), h: abs(size.height)))
    }
    throw Unreadable(name: url.lastPathComponent)
  }

  /// A picture whose four corners are see-through is a cut-out, and stands on the wall with no card.
  private static func isCutOut(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
    return [(0, 0), (15, 0), (0, 15), (15, 15)].allSatisfy { data[($0.1 * 16 + $0.0) * 4 + 3] < 12 }
  }

  /// A picture has no parts of its own, so it assembles from a grid of its own pieces.
  static func grid(for material: Material) -> [Piece] {
    let height = (Grain.cardWidth * min(2.2, max(0.45, material.h / material.w))).rounded()
    let side = Grain.cardWidth / 5
    let rows = max(1, Int((height / side).rounded()))
    let cell = height / Double(rows)
    return (0..<rows).flatMap { row in
      (0..<5).map { column in
        Piece(kind: .media, x: Double(column) * side, y: Double(row) * cell, w: side, h: cell, radius: 0)
      }
    }
  }

  static func picture(of material: Material) async -> CGImage? {
    let url = Paths.materials.appending(path: material.src)
    if material.kind == .image { return await thumbnail(url) }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: Grain.cardWidth * 2, height: 0)
    return try? await generator.image(at: .zero).image
  }

  private nonisolated static func thumbnail(_ url: URL) async -> CGImage? {
    await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }.value
  }
}
