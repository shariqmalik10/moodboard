import AppKit
import WebKit

/// One connected project as the panel shows it.
struct ProjectLine: Identifiable, Equatable {
  var id: String { slug }
  var slug: String
  var name: String
  var root: String
  var shown: Int
  var skipped: [SkippedComponent]
  var progress: String?
  var problem: String?
}

@Observable
final class ProjectsModel {
  var lines: [ProjectLine] = []
  var isChoosing = false
}

/// Keeps the wall and connected Next.js projects in step. A saved edit reaches a running tile through the
/// project's own hot reload, and this keeps the rest current: which tiles exist, their size, and their plates.
/// Going the other way, a moved dial becomes an edit to the source file.
final class ProjectSync {
  private struct Job {
    var found: FoundComponent
    var slug: String
    var attempts = 0
  }

  private final class Measurer {
    let web: StageWebView
    var job: Job?
    var deadline: Task<Void, Never>?

    init(web: StageWebView) {
      self.web = web
    }
  }

  let state = ProjectsModel()
  private unowned let app: AppModel
  private var servers: [String: ProjectServer] = [:]
  private var restarts: [String: Int] = [:]
  private var progress: [String: (done: Int, total: Int)] = [:]
  private var problems: [String: String] = [:]
  /// A start this slow is usually macOS waiting for the person to allow the folder.
  private var slowToStart = Set<String>()
  private static let patience = Duration.seconds(6)
  /// Filled at connect, so the wall turns to the new project once it has something to show.
  private var revealing = Set<String>()

  private var queue: [Job] = []
  private var measurers: [Measurer] = []
  private var starting: Task<Void, Never>?
  private static let concurrency = 3
  private static let settle = Duration.milliseconds(350)

  private var latestHash: [String: String] = [:]
  /// What the source holds for each open dial, so only a real move becomes a write.
  private var seen: [String: JSON] = [:]
  private var pending: [String: JSON] = [:]
  private var flushing: [String: Task<Void, Never>] = [:]
  private var scheduled: [String: Task<Void, Never>] = [:]

  init(app: AppModel) {
    self.app = app
    refreshLines()
  }

  // MARK: Connecting

  func startAll() {
    for project in ProjectCatalog.projects { startServer(project) }
    refreshLines()
  }

  func stopAll() {
    servers.values.forEach { $0.stop() }
    servers = [:]
  }

  func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Connect"
    panel.message = "Choose a Next.js project. Its components join the wall, and moving a dial edits their source files."
    panel.beginSheetModal(for: app.window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated {
        Task {
          do {
            try await self?.connect(url)
          } catch {
            self?.app.chrome?.say(error.localizedDescription)
          }
        }
      }
    }
  }

  /// Checks what can be checked before anything runs, so a bad folder gets a plain answer.
  /// The first read of a folder under Documents, Desktop or Downloads waits on macOS's prompt, so this never runs on the main thread.
  nonisolated static func problem(with root: URL) -> String? {
    let files = FileManager.default
    let name = root.lastPathComponent
    do {
      _ = try files.contentsOfDirectory(atPath: root.path)
    } catch CocoaError.fileReadNoPermission {
      return refused
    } catch {}
    guard files.fileExists(atPath: root.appending(path: "package.json").path) else { return "\(name) has no package.json, so it isn't a Next.js project." }
    guard files.fileExists(atPath: root.appending(path: "node_modules").path) else { return "\(name) has no node_modules. Install its packages first, then connect it." }
    guard files.fileExists(atPath: root.appending(path: "node_modules/react").path) else { return "\(name) doesn't use React, so there's nothing to show from it." }
    return nil
  }

  nonisolated static let refused = "Moodboard can't read this folder. If macOS asks, choose Allow, or turn Moodboard on in System Settings, under Privacy & Security, Files and Folders."

  @discardableResult
  func connect(_ url: URL) async throws -> ConnectedProject {
    let path = url.standardizedFileURL.path
    if let problem = await Task.detached(operation: { Self.problem(with: url) }).value { throw ToolError(problem) }
    if let known = ProjectCatalog.projects.first(where: { $0.root == path }) { return known }
    let manifest = (try? Data(contentsOf: url.appending(path: "package.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }
    let name = manifest?["name"] as? String ?? url.lastPathComponent
    let wanted = name.lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let project = ConnectedProject(root: path, name: name, slug: ProjectCatalog.freeSlug(wanted.isEmpty ? "project" : wanted, root: path))
    ProjectCatalog.add(project)
    revealing.insert(project.slug)
    startServer(project)
    refreshLines()
    return project
  }

  func disconnect(slug: String) {
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    Task {
      if let open = app.focus?.openItemId, ProjectCatalog.project(of: open)?.slug == slug {
        app.focus?.close()
        while app.focus?.tile != nil { try? await Task.sleep(for: .milliseconds(30)) }
      }
      servers[slug]?.stop()
      servers[slug] = nil
      queue.removeAll { $0.slug == slug }
      progress[slug] = nil
      problems[slug] = nil
      let ids = project.components.map(\.id)
      ProjectCatalog.remove(slug: slug)
      for id in ids {
        DialState.write(id, nil)
        app.statuses.forget(id)
        forget(id)
      }
      app.store?.drop(Set(ids))
      refreshLines()
    }
  }

  private func forget(_ id: String) {
    latestHash[id] = nil
    seen[id] = nil
    pending[id] = nil
    scheduled[id]?.cancel()
    scheduled[id] = nil
  }

  private func startServer(_ project: ConnectedProject) {
    let root = URL(filePath: project.root, directoryHint: .isDirectory)
    let slug = project.slug
    let server = ProjectServer(root: root, slug: slug)
    server.onEvent = { [weak self] event in self?.receive(event, slug: slug) }
    servers[slug] = server
    problems[slug] = nil
    slowToStart.remove(slug)
    Task {
      let problem = await Task.detached(operation: { Self.problem(with: root) }).value
      guard servers[slug] === server else { return }
      if let problem {
        servers[slug] = nil
        problems[slug] = problem
        refreshLines()
        return
      }
      server.start()
    }
    Task {
      try? await Task.sleep(for: Self.patience)
      guard servers[slug] === server, server.port == nil else { return }
      slowToStart.insert(slug)
      refreshLines()
    }
  }

  private func receive(_ event: ProjectServer.Event, slug: String) {
    switch event {
    case .listening(let port, _):
      restarts[slug] = 0
      slowToStart.remove(slug)
      ProjectCatalog.setPort(port, slug: slug)
      wakeStages(slug: slug)
    case .components(let items, let bySelf):
      arrived(items, slug: slug, bySelf: bySelf)
    case .stopped(let reason):
      ProjectCatalog.setPort(nil, slug: slug)
      servers[slug] = nil
      slowToStart.remove(slug)
      let tries = restarts[slug] ?? 0
      if tries < 1, let project = ProjectCatalog.project(slug: slug) {
        restarts[slug] = tries + 1
        startServer(project)
      } else {
        problems[slug] = reason
      }
    }
    refreshLines()
  }

  /// Stages and plates asked for this project before its server was up, so they ask again.
  private func wakeStages(slug: String) {
    for stage in app.pool.all {
      if let id = stage.itemId, id.hasPrefix("project/\(slug)/") { stage.reload() }
    }
    for component in ProjectCatalog.project(slug: slug)?.components ?? [] { app.plates?.request(component.id) }
    if let open = app.focus?.openItemId, open.hasPrefix("project/\(slug)/") { app.focus?.reloadPanel() }
  }

  // MARK: What's on the wall

  private func arrived(_ items: [FoundComponent], slug: String, bySelf: Bool) {
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    let rows = Dictionary(project.components.map { ($0.id, $0) }) { first, _ in first }
    let skipped = Dictionary(project.skipped.map { ($0.id, $0) }) { first, _ in first }
    var added = 0
    var edited: [String] = []
    for item in items {
      // A quick undo lands back on the hash the row still holds, and it's an edit all the same.
      let wasDifferent = latestHash[item.id].map { $0 != item.hash } ?? false
      latestHash[item.id] = item.hash
      if let row = rows[item.id] {
        if row.hash != item.hash || wasDifferent { edited.append(item.id) }
        if row.hash != item.hash || queue.contains(where: { $0.found.id == item.id }) { enqueue(Job(found: item, slug: slug), first: true) }
      } else if skipped[item.id]?.hash != item.hash {
        enqueue(Job(found: item, slug: slug), first: false)
        added += 1
      }
    }
    if added > 0 {
      let before = progress[slug]
      progress[slug] = (done: before?.done ?? 0, total: (before?.total ?? 0) + added)
    }

    let present = Set(items.map(\.id))
    let gone = rows.keys.filter { !present.contains($0) }
    if !gone.isEmpty { drop(Set(gone), slug: slug) }
    queue.removeAll { $0.slug == slug && !present.contains($0.found.id) }
    if skipped.keys.contains(where: { !present.contains($0) }) {
      ProjectCatalog.edit(slug: slug) { $0.skipped.removeAll { !present.contains($0.id) } }
    }

    if !bySelf, let open = app.focus?.openItemId, edited.contains(open) { app.focus?.reloadPanel() }
    // An edit elsewhere may have taken back what a dial wrote, and the mark on the tile should say so.
    if !bySelf {
      for id in edited where app.statuses.status(id).written > 0 { Task { _ = await record(id) } }
    }
    startSoon()
    refreshLines()
  }

  private func drop(_ ids: Set<String>, slug: String) {
    Task {
      if let open = app.focus?.openItemId, ids.contains(open) {
        app.focus?.close()
        while app.focus?.tile != nil { try? await Task.sleep(for: .milliseconds(30)) }
      }
      ProjectCatalog.edit(slug: slug) { $0.components.removeAll { ids.contains($0.id) } }
      for id in ids {
        DialState.write(id, nil)
        app.statuses.forget(id)
        forget(id)
      }
      app.store?.drop(ids)
      refreshLines()
    }
  }

  private func enqueue(_ job: Job, first: Bool) {
    queue.removeAll { $0.found.id == job.found.id }
    if first { queue.insert(job, at: 0) } else { queue.append(job) }
  }

  /// Waits for a run of saves to end, so a dragged dial measures once.
  private func startSoon() {
    starting?.cancel()
    starting = Task {
      try? await Task.sleep(for: Self.settle)
      guard !Task.isCancelled else { return }
      pump()
    }
  }

  private func pump() {
    while measurers.filter({ $0.job != nil }).count < Self.concurrency, let at = queue.firstIndex(where: { ProjectCatalog.url(for: $0.found.id, flag: "measure") != nil }) {
      let job = queue.remove(at: at)
      guard let url = ProjectCatalog.url(for: job.found.id, flag: "measure") else { continue }
      let measurer = measurers.first { $0.job == nil } ?? makeMeasurer()
      measurer.job = job
      measurer.web.load(URLRequest(url: url))
      measurer.deadline = Task { [weak self, weak measurer] in
        try? await Task.sleep(for: .seconds(25))
        guard !Task.isCancelled, let self, let measurer else { return }
        self.failed(measurer, reason: "It took too long to load.")
      }
    }
    if queue.isEmpty, !measurers.contains(where: { $0.job != nil }) {
      // Each web view holds a whole process, so they don't stay around.
      measurers.forEach { $0.web.removeFromSuperview() }
      measurers = []
    }
  }

  private func makeMeasurer() -> Measurer {
    let measurer = Measurer(web: app.host.makeWebView(frame: CGRect(x: 0, y: 0, width: 760, height: 600)))
    app.root.backstage.addSubview(measurer.web)
    measurers.append(measurer)
    return measurer
  }

  func owns(_ web: WKWebView?) -> Bool { measurers.contains { $0.web === web } }

  func handle(_ web: WKWebView?, message: JSON) {
    guard let measurer = measurers.first(where: { $0.web === web }), let job = measurer.job, message["id"] as? String == job.found.id else { return }
    switch message["type"] as? String {
    case "measured":
      measured(measurer, job, width: message["width"] as? Double ?? 0, height: message["height"] as? Double ?? 0, ground: message["ground"] as? String ?? "#ffffff", blank: message["blank"] as? Bool ?? true)
    case "failed":
      failed(measurer, reason: message["message"] as? String ?? "It didn't load.")
    default:
      break
    }
  }

  private func finish(_ measurer: Measurer) {
    measurer.deadline?.cancel()
    measurer.job = nil
    measurer.web.loadHTMLString("", baseURL: nil)
  }

  private func failed(_ measurer: Measurer, reason: String) {
    guard var job = measurer.job else { return }
    finish(measurer)
    // Vite swaps its bundled packages when it meets a new one, and a page caught in the swap fails once.
    if job.attempts < 2, reason.contains("dynamically imported") || reason.contains("Importing a module script") {
      job.attempts += 1
      enqueue(job, first: false)
    } else {
      skip(job, reason: reason)
    }
    pump()
  }

  private func skip(_ job: Job, reason: String) {
    let id = job.found.id
    // A tile already on the wall keeps its last good look while its file is mid-edit.
    if ProjectCatalog.contains(id) { return }
    tick(job.slug)
    ProjectCatalog.edit(slug: job.slug) { project in
      project.skipped.removeAll { $0.id == id }
      project.skipped.append(SkippedComponent(id: id, title: job.found.title, file: job.found.file, hash: job.found.hash, reason: reason))
    }
    refreshLines()
  }

  private func tick(_ slug: String) {
    guard let current = progress[slug] else { return }
    let done = current.done + 1
    progress[slug] = done >= current.total ? nil : (done: done, total: current.total)
    if done >= current.total, let project = ProjectCatalog.project(slug: slug) {
      let hidden = project.skipped.isEmpty ? "" : " \(project.skipped.count) can't stand alone. The connect panel says why."
      app.chrome?.say("\(project.name) has \(project.components.count) on the wall.\(hidden)")
    }
  }

  private func measured(_ measurer: Measurer, _ job: Job, width: Double, height: Double, ground: String, blank: Bool) {
    finish(measurer)
    defer { pump() }
    if blank {
      skip(job, reason: "It draws nothing without real data, or it's only an icon.")
      return
    }
    let id = job.found.id
    let row = ProjectComponent(id: id, title: job.found.title, file: job.found.file, exportName: job.found.exportName, hash: job.found.hash, viewport: ProjectSizing.viewport(width: width, height: height), ground: ground, dark: ProjectSizing.isDark(hex: ground))
    let existing = ProjectCatalog.row(id)
    ProjectCatalog.edit(slug: job.slug) { project in
      project.skipped.removeAll { $0.id == id }
      if let at = project.components.firstIndex(where: { $0.id == id }) {
        project.components[at] = row
      } else {
        project.components.append(row)
      }
    }
    if existing == nil {
      arrive(row, slug: job.slug)
      tick(job.slug)
    } else {
      if existing?.viewport != row.viewport || existing?.ground != row.ground { app.store?.refresh() }
      app.plates?.invalidate(id)
    }
    refreshLines()
  }

  /// One more on the wall. While a whole project comes in, tiles gather at the ends of the columns. Later, one new
  /// component arrives where the person is looking.
  private func arrive(_ row: ProjectComponent, slug: String) {
    guard let store = app.store else { return }
    if store.isHidden(row.id) { return }
    if progress[slug] != nil {
      store.add(row.id)
      if revealing.remove(slug) != nil { app.show(.wall, filter: .project(slug)) }
      app.plates?.request(row.id)
    } else {
      let slot = app.canvas?.slotNearCenter()
      store.insert(id: row.id, column: slot?.column ?? 0, index: slot?.index ?? 0)
      app.plates?.request(row.id, first: true)
      app.canvas?.welcome(row.id)
      app.chrome?.say("\(row.title) joined from \(ProjectCatalog.name(of: slug) ?? slug).")
    }
  }

  private func refreshLines() {
    state.lines = ProjectCatalog.projects.map { project in
      let progress = progress[project.slug].map { "Adding \($0.done) of \($0.total)…" }
      let waking = servers[project.slug] != nil && servers[project.slug]?.port == nil ? (slowToStart.contains(project.slug) ? "Still starting. If macOS asks about this folder, choose Allow." : "Starting…") : nil
      return ProjectLine(slug: project.slug, name: project.name, root: project.root, shown: project.components.count, skipped: project.skipped, progress: progress ?? waking, problem: problems[project.slug])
    }
  }

  // MARK: The panel

  /// A component's panel, read from the source every time, because a write's hash can arrive after the file is already back to its old text.
  func record(_ id: String) async -> Data? {
    guard let project = ProjectCatalog.project(of: id), let server = servers[project.slug] else { return nil }
    guard let data = try? await server.dials(id: id), let record = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
    seen[id] = record["values"] as? JSON ?? [:]
    showFiles(record["files"] as? [String], for: id)
    applyJournal(record, to: id)
    return data
  }

  /// A dial can land in a stylesheet too, which other components may share, so the panel names every file.
  private func showFiles(_ files: [String]?, for id: String) {
    guard let files, app.focus?.openItemId == id else { return }
    app.focus?.inspector.model.sourceFile = files.joined(separator: ", ")
  }

  /// What the panel just saved. Sample props stay in the app, and everything else goes to the source.
  func tuned(_ id: String, state: Any?, byPerson: Bool) {
    guard var whole = state as? JSON else {
      DialState.write(id, nil)
      app.pool.stages(showing: id).forEach { $0.tune(saved: [:]) }
      app.statuses.tuneChanged(id)
      return
    }
    let values = whole["values"] as? JSON ?? [:]
    let (samples, source) = Self.split(values)
    whole["values"] = samples
    if let base = whole["baseValues"] as? JSON { whole["baseValues"] = Self.split(base).samples }
    DialState.write(id, try? JSONSerialization.data(withJSONObject: whole))
    app.pool.stages(showing: id).forEach { $0.tune(saved: samples) }
    app.statuses.tuneChanged(id)
    if byPerson {
      queueWrites(id, source)
    } else {
      // The panel loading, in the form it holds values. That's the baseline a person's move is measured from.
      seen[id, default: [:]].merge(source) { _, new in new }
    }
  }

  /// A dial moved from outside the panel: a revert, or Claude Code.
  func setDials(_ id: String, values: JSON) {
    let (samples, source) = Self.split(values)
    if !samples.isEmpty {
      DialState.merge(id, values: samples)
      app.pool.stages(showing: id).forEach { $0.tune(saved: DialState.saved(id)) }
      app.statuses.tuneChanged(id)
    }
    queueWrites(id, source)
    if app.focus?.openItemId == id { app.focus?.inspector.setDials(values) }
  }

  /// Waits for what's been asked of this component's file to land.
  func settled(_ id: String) async {
    while scheduled[id] != nil || flushing[id] != nil || pending[id] != nil {
      try? await Task.sleep(for: .milliseconds(30))
    }
  }

  static func split(_ values: JSON) -> (samples: JSON, source: JSON) {
    var samples: JSON = [:]
    var source: JSON = [:]
    for (path, value) in values where path != "reset" {
      if path.hasPrefix(ProjectCatalog.samplePrefix) { samples[path] = value } else { source[path] = value }
    }
    return (samples, source)
  }

  private func queueWrites(_ id: String, _ source: JSON) {
    var known = seen[id] ?? [:]
    let moved = source.filter { path, value in
      guard let before = known[path] as? NSObject, let after = value as? NSObject else { return true }
      return !before.isEqual(after)
    }
    guard !moved.isEmpty else { return }
    known.merge(moved) { _, new in new }
    seen[id] = known
    pending[id, default: [:]].merge(moved) { _, new in new }
    // A drag writes as it goes, so the tile follows the dial instead of waiting for the hand to stop.
    guard scheduled[id] == nil else { return }
    scheduled[id] = Task {
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled else { return }
      scheduled[id] = nil
      flush(id)
    }
  }

  private func flush(_ id: String) {
    guard flushing[id] == nil, let values = pending.removeValue(forKey: id), let project = ProjectCatalog.project(of: id), let server = servers[project.slug] else { return }
    flushing[id] = Task {
      do {
        apply(try await server.write(id: id, values: values), to: id)
      } catch {
        app.chrome?.say("Couldn't write to \(ProjectCatalog.row(id)?.file ?? "the file"). \(error.localizedDescription)")
      }
      flushing[id] = nil
      if pending[id] != nil { flush(id) }
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
