import Foundation

/// Every dial move, whether from the panel, a revert, or Claude Code. A component from the library keeps all its values in
/// the app. A connected project's component keeps only its sample props in the app, and the rest become edits to its source.
final class Dials {
  private unowned let app: AppModel
  private var writers: [String: SourceWriter] = [:]

  init(app: AppModel) {
    self.app = app
  }

  /// Sorts a project component's values: sample props stay in the app, everything else goes to the source.
  static func split(_ values: JSON) -> (samples: JSON, source: JSON) {
    var samples: JSON = [:]
    var source: JSON = [:]
    for (path, value) in values where path != "reset" {
      if path.hasPrefix(ProjectCatalog.samplePrefix) { samples[path] = value } else { source[path] = value }
    }
    return (samples, source)
  }

  /// A library component's values all stay in the app.
  private func split(_ id: String, _ values: JSON) -> (samples: JSON, source: JSON) {
    ProjectCatalog.contains(id) ? Self.split(values) : (values, [:])
  }

  /// What the panel just saved: DialKit's whole state, or nothing for a panel reset to the design.
  func panelSaved(_ id: String, state: Any?, byPerson: Bool) {
    guard var whole = state as? JSON else {
      DialState.write(id, nil)
      retune(id, saved: [:])
      return
    }
    let (samples, source) = split(id, whole["values"] as? JSON ?? [:])
    whole["values"] = samples
    if ProjectCatalog.contains(id), let base = whole["baseValues"] as? JSON { whole["baseValues"] = Self.split(base).samples }
    DialState.write(id, try? JSONSerialization.data(withJSONObject: whole))
    retune(id, saved: samples)
    guard ProjectCatalog.contains(id) else { return }
    if byPerson {
      queueWrites(id, source)
    } else {
      // The panel loading, in the form it holds values. That's the baseline a person's move is measured from.
      writer(id).seen.merge(source) { _, new in new }
    }
  }

  /// Dials moved from outside the panel: a revert, or Claude Code.
  func set(_ id: String, values: JSON) {
    let (samples, source) = split(id, values)
    if !samples.isEmpty {
      DialState.merge(id, values: samples)
      retune(id, saved: DialState.saved(id))
    }
    if ProjectCatalog.contains(id) { queueWrites(id, source) }
    if app.focus?.openItemId == id {
      app.focus?.inspector.setDials(values)
    } else if !ProjectCatalog.contains(id) {
      // A project's plate follows its source file, which tells the wall when it changes.
      app.plates?.invalidate(id)
    }
  }

  /// Moves dials for Claude Code once it has checked them against the component, and returns every dial now changed.
  func setChecked(_ id: String, values: JSON) async throws -> Any {
    let known = try await names(id)
    let unknown = values.keys.filter { !known.contains($0) && !(ProjectCatalog.contains(id) && $0.hasPrefix(ProjectCatalog.samplePrefix)) }
    guard unknown.isEmpty else { throw ToolError("\(id) has no dial called \(unknown.sorted().joined(separator: ", ")). It has: \(known.sorted().joined(separator: ", "))") }
    set(id, values: values)
    guard ProjectCatalog.contains(id) else { return try await app.tools.brief(id)["changes"] ?? [] }
    await settled(id)
    return app.statuses.changes(id).map { ["dial": $0.dial, "from": $0.from, "to": $0.to] as JSON }
  }

  private func names(_ id: String) async throws -> Set<String> {
    guard ProjectCatalog.contains(id) else { return Set(try await app.tools.brief(id)["dials"] as? [String] ?? []) }
    guard let record = await record(id), let values = ((try? JSONSerialization.jsonObject(with: record)) as? JSON)?["values"] as? JSON else {
      throw ToolError("The project's server isn't running.")
    }
    return Set(values.keys)
  }

  private func retune(_ id: String, saved: JSON) {
    app.pool.stages(showing: id).forEach { $0.tune(saved: saved) }
    app.statuses.tuneChanged(id)
  }

  /// Forgets a component that left the wall.
  func forget(_ id: String) {
    guard let writer = writers.removeValue(forKey: id) else { return }
    writer.scheduled?.cancel()
    writer.waiting.forEach { $0.resume() }
  }

  // MARK: A project's source

  /// A component's panel, read from the source every time, because a write's hash can arrive after the file is already back to its old text.
  func record(_ id: String) async -> Data? {
    guard let server = app.projects.server(for: id), let data = try? await server.dials(id: id), let record = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
    writer(id).seen = record["values"] as? JSON ?? [:]
    // A dial can land in a stylesheet too, which other components may share, so the panel names every file.
    if let files = record["files"] as? [String], app.focus?.openItemId == id { app.focus?.inspector.model.sourceFile = files.joined(separator: ", ") }
    applyJournal(record, to: id)
    return data
  }

  /// Returns once what's been asked of this component's file has landed.
  func settled(_ id: String) async {
    guard let writer = writers[id], !writer.isIdle else { return }
    await withCheckedContinuation { writer.waiting.append($0) }
  }

  private func writer(_ id: String) -> SourceWriter {
    if let writer = writers[id] { return writer }
    let writer = SourceWriter()
    writers[id] = writer
    return writer
  }

  private func queueWrites(_ id: String, _ source: JSON) {
    let writer = writer(id)
    let moved = source.filter { path, value in
      guard let before = writer.seen[path] as? NSObject, let after = value as? NSObject else { return true }
      return !before.isEqual(after)
    }
    guard !moved.isEmpty else { return }
    writer.seen.merge(moved) { _, new in new }
    writer.pending.merge(moved) { _, new in new }
    // A drag writes as it goes, so the tile follows the dial instead of waiting for the hand to stop.
    guard writer.scheduled == nil else { return }
    writer.scheduled = Task {
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled else { return }
      writer.scheduled = nil
      flush(id, writer)
    }
  }

  private func flush(_ id: String, _ writer: SourceWriter) {
    guard writer.flushing == nil, !writer.pending.isEmpty else { return writer.resumeIfIdle() }
    let values = writer.pending
    writer.pending = [:]
    guard let server = app.projects.server(for: id) else { return writer.resumeIfIdle() }
    writer.flushing = Task {
      do {
        apply(try await server.write(id: id, values: values), to: id)
      } catch {
        app.chrome?.say("Couldn't write to \(ProjectCatalog.row(id)?.file ?? "the file"). \(error.localizedDescription)")
      }
      writer.flushing = nil
      if writer.pending.isEmpty { writer.resumeIfIdle() } else { flush(id, writer) }
    }
  }

  private func applyJournal(_ result: JSON, to id: String) {
    app.statuses.setWrites(id, (result["journal"] as? [JSON] ?? []).compactMap { entry in
      guard let path = entry["path"] else { return nil }
      return DialChange(["dial": path, "from": entry["fromValue"] ?? NSNull(), "to": entry["toValue"] ?? NSNull()])
    })
  }

  private func apply(_ result: JSON, to id: String) {
    applyJournal(result, to: id)
    let conflicts = result["conflicts"] as? [String] ?? []
    guard !conflicts.isEmpty else { return }
    // The file moved under the panel, so what the panel shows can't be trusted any more.
    app.chrome?.say("\(ProjectCatalog.row(id)?.file ?? "That file") changed while you were tuning, so the dials reloaded from it.")
    if app.focus?.openItemId == id { app.focus?.reloadPanel() }
  }
}

/// One project component's dial moves on their way into its source file.
private final class SourceWriter {
  /// What the source holds for each dial, so only a real move becomes a write.
  var seen: JSON = [:]
  var pending: JSON = [:]
  var scheduled: Task<Void, Never>?
  var flushing: Task<Void, Never>?
  var waiting: [CheckedContinuation<Void, Never>] = []

  var isIdle: Bool { scheduled == nil && flushing == nil && pending.isEmpty }

  func resumeIfIdle() {
    guard isIdle else { return }
    waiting.forEach { $0.resume() }
    waiting = []
  }
}
