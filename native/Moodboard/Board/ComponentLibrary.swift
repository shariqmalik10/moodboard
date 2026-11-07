import AppKit

/// A design imported from Paper, kept on disk as exactly what Paper gave us plus what the wall needs.
struct ComponentRecord: Codable {
  struct Source: Codable {
    var kind = "paper"
    var fileId: String
    var fileName: String?
    var nodeId: String
  }

  struct Token: Codable, Equatable {
    var name: String
    var type: String
    var value: String
    var description: String?
  }

  var id: String
  var title: String
  var jsx: String
  var tokens: [Token]
  var viewport: Size
  var source: Source
  var ground: String
  var dark: Bool
  var importedAt: Date
}

enum ComponentLibrary {
  private static var cache: [String: ComponentRecord]?

  private static func url(_ id: String) -> URL {
    Paths.components.appending(path: Paths.fileName(for: id) + ".json")
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func all() -> [String: ComponentRecord] {
    if let cache { return cache }
    var found: [String: ComponentRecord] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(at: Paths.components, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
      if let data = try? Data(contentsOf: file), let record = try? decoder.decode(ComponentRecord.self, from: data) { found[record.id] = record }
    }
    cache = found
    return found
  }

  static func record(_ id: String) -> ComponentRecord? { all()[id] }

  static func save(_ record: ComponentRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url(record.id), options: .atomic)
    cache = nil
  }

  static func delete(_ id: String) {
    try? FileManager.default.removeItem(at: url(id))
    cache = nil
  }

  static func contains(_ id: String) -> Bool { all()[id] != nil }

  static func recordData(_ id: String) -> Data? {
    guard contains(id) else { return nil }
    return try? Data(contentsOf: url(id))
  }

  static func items() -> [String: Item] {
    all().mapValues { record in
      Item(
        row: CatalogRow(
          id: record.id, project: "paper", title: record.title, viewport: record.viewport,
          crop: Crop(x: 0, y: 0, w: record.viewport.w, h: record.viewport.h), dark: record.dark, ground: record.ground
        )
      )
    }
  }
}
