import AppKit

/// Brings a design from Paper onto the wall. Importing the same design again updates it in place, and
/// its tuned values carry over wherever the design still has that value.
final class Importer {
  private unowned let model: AppModel
  let paper = PaperClient()

  init(model: AppModel) {
    self.model = model
  }

  static func id(for node: PaperClient.Node) -> String {
    let slug = node.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
      .split(separator: "-").joined(separator: "-")
    return "paper/\(slug.isEmpty ? "design" : String(slug.prefix(36)))-\(stableHash(Data((node.fileId + node.id).utf8)).prefix(6))"
  }

  @discardableResult
  func importNode(_ node: PaperClient.Node) async throws -> ComponentRecord {
    let jsx = try await paper.jsx(node)
    let tokens = try await paper.tokens(fileId: node.fileId)
    let id = Self.id(for: node)
    let tokenData = try JSONEncoder().encode(tokens)
    let tokenJSON = try JSONSerialization.jsonObject(with: tokenData)
    let data = try await model.runtime.call("return window.__runtime.inspectPaper(jsx, tokens)", ["jsx": jsx, "tokens": tokenJSON])
    let inspected = try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    let record = ComponentRecord(
      id: id, title: node.name, jsx: jsx, tokens: tokens, viewport: Size(w: max(node.width, 40), h: max(node.height, 40)),
      source: .init(fileId: node.fileId, fileName: node.fileName, nodeId: node.id),
      ground: inspected["ground"] as? String ?? "#f4f5f1", dark: inspected["dark"] as? Bool ?? false, importedAt: .now
    )

    let isNew = !ComponentLibrary.contains(id)
    let before = isNew ? nil : try? await model.tools.brief(id)
    try ComponentLibrary.save(record)
    if isNew {
      model.store?.refresh()
      await model.plates?.bake(id)
      model.place(id)
    } else {
      model.store?.refresh()
      model.pool.stages(showing: id).forEach { $0.reload() }
      model.plates?.invalidate(id)
      await noteLostTune(id, before: before)
    }
    await model.statuses.refresh(id)
    model.statuses.setPaper(id, .current)
    return record
  }

  /// A dial's name comes from the value it tunes, so a value changed in Paper leaves that tune with nothing to apply to.
  private func noteLostTune(_ id: String, before: JSON?) async {
    guard let before, let after = try? await model.tools.brief(id) else { return }
    let dials = Set(after["dials"] as? [String] ?? [])
    let tuned = (before["changes"] as? [JSON] ?? []).compactMap { $0["dial"] as? String }
    model.statuses.recordLostTune(id, tuned.filter { !dials.contains($0) })
  }

  /// Brings in every design that Paper has changed, and says what couldn't be.
  func updateChanged() async {
    let ids = ComponentLibrary.all().keys.filter { model.statuses.status($0).paper == .changed }
    for id in ids.sorted() {
      do {
        try await update(id)
      } catch {
        model.chrome?.say(error.localizedDescription)
      }
    }
  }

  func importSelection() async throws -> [ComponentRecord] {
    let nodes = try await paper.selection()
    guard !nodes.isEmpty else { throw PaperClient.Failure.tool("Nothing is selected in Paper.") }
    var records: [ComponentRecord] = []
    for node in nodes { records.append(try await importNode(node)) }
    return records
  }

  /// Re-reads a design from Paper. A design that has been deleted there stays on the wall as it was.
  func update(_ id: String) async throws {
    guard let record = ComponentLibrary.record(id) else { throw PaperClient.Failure.tool("That didn't come from Paper.") }
    let node = try await paper.nodeInfo(fileId: record.source.fileId, fileName: record.source.fileName, nodeId: record.source.nodeId)
    try await importNode(node)
  }
}
