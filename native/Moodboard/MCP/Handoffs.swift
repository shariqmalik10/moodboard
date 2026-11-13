import AppKit

/// What one line of Claude Code's `stream-json` output means for the person watching.
enum HandoffEvent: Equatable {
  case started(session: String)
  case working(String, changed: String?)
  case finished(String, session: String?)
  case failed(String, session: String?)
  case nothing

  static func read(_ line: String) -> HandoffEvent {
    guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else { return .nothing }
    let session = event["session_id"] as? String
    switch event["type"] as? String {
    case "system":
      guard event["subtype"] as? String == "init", let session else { return .nothing }
      return .started(session: session)
    case "assistant":
      let blocks = (event["message"] as? JSON)?["content"] as? [JSON] ?? []
      guard let block = blocks.last else { return .nothing }
      if block["type"] as? String == "tool_use" { return describe(tool: block["name"] as? String ?? "", input: block["input"] as? JSON ?? [:]) }
      if block["type"] as? String == "text", let text = firstLine(block["text"] as? String) { return .working(text, changed: nil) }
      return .nothing
    case "result":
      let summary = firstLine(event["result"] as? String) ?? ""
      if event["is_error"] as? Bool == true || event["subtype"] as? String != "success" { return .failed(summary, session: session) }
      return .finished(summary, session: session)
    default:
      return .nothing
    }
  }

  private static func firstLine(_ text: String?) -> String? {
    text?.split(whereSeparator: \.isNewline).first.map(String.init)
  }

  private static func describe(tool: String, input: JSON) -> HandoffEvent {
    let path = input["file_path"] as? String ?? input["notebook_path"] as? String
    let name = path.map { URL(filePath: $0).lastPathComponent } ?? "a file"
    switch tool {
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return .working("Editing \(name)", changed: path)
    case "Read": return .working("Reading \(name)", changed: nil)
    case "Grep", "Glob": return .working("Searching the project", changed: nil)
    case "Bash": return .working("Running a command", changed: nil)
    default: return .working("Working", changed: nil)
    }
  }
}

/// Hands over each line the moment it's complete. `FileHandle.bytes.lines` holds a line back until the
/// next one starts, so the status would lag the work and the last line could arrive after the process ended.
final class LineReader {
  private let handle: FileHandle
  private let onLine: (String) -> Void
  private var pending = Data()

  init(_ handle: FileHandle, onLine: @escaping (String) -> Void) {
    self.handle = handle
    self.onLine = onLine
    handle.readabilityHandler = { [self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      DispatchQueue.main.async { MainActor.assumeIsolated { self.feed(data) } }
    }
  }

  private func feed(_ data: Data) {
    pending.append(data)
    while let end = pending.firstIndex(of: 0x0a) {
      onLine(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
      pending = Data(pending[pending.index(after: end)...])
    }
  }

  func stop() {
    handle.readabilityHandler = nil
  }
}

/// Sends a tuned component to Claude Code in a repository the person chose, and shows how it's going.
/// It runs only when they press Send, and can edit files in that repository without asking each time.
final class Handoffs {
  private unowned let app: AppModel
  private var runs: [String: HandoffRun] = [:]

  private static let recentsKey = "recentRepositories"
  private var showedProjectRoot = false
  /// Apps opened from the Dock get a bare PATH, and a non-interactive login shell doesn't read `.zshrc`,
  /// which is where installers usually add these.
  private static let searchPath = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { NSString(string: $0).expandingTildeInPath }

  init(app: AppModel) {
    self.app = app
  }

  func run(for id: String) -> HandoffRun? { runs[id] }

  private var recents: [URL] {
    get { (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) } }
    set { UserDefaults.standard.set(newValue.prefix(6).map(\.path), forKey: Self.recentsKey) }
  }

  func perform(_ action: HandoffAction, in inspector: InspectorModel) {
    if case .signIn = action { return runInTerminal("claude auth login", named: "sign-in") }
    if case .chooseRepository = action { return chooseRepository(for: inspector) }
    guard let id = inspector.itemId else { return }
    switch action {
    case .send:
      guard let repository = inspector.repository else { return }
      send(id: id, repository: repository)
      inspector.run = runs[id]
    case .stop: stop(id)
    case .resume: resume(id)
    case .signIn, .chooseRepository: break
    }
  }

  func show(id: String, in inspector: InspectorModel) {
    inspector.run = runs[id]
    inspector.recentRepositories = recents
    inspector.resumableSession = app.statuses.built(id)?.session
    // A project's own component goes back to its own repository, whatever was chosen for the last one.
    if let root = ProjectCatalog.project(of: id)?.root {
      inspector.repository = URL(filePath: root, directoryHint: .isDirectory)
      showedProjectRoot = true
    } else {
      inspector.repository = showedProjectRoot ? recents.first : inspector.repository ?? recents.first
      showedProjectRoot = false
    }
  }

  private func chooseRepository(for inspector: InspectorModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Choose"
    panel.message = "Claude Code will work in this folder and can edit its files."
    panel.beginSheetModal(for: app.window) { [weak self, weak inspector] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated {
        inspector?.repository = url
        self?.remember(url)
        if let self { inspector?.recentRepositories = self.recents }
      }
    }
  }

  private func remember(_ url: URL) {
    recents = [url] + recents.filter { $0 != url }
  }

  func send(id: String, repository: URL) {
    // A finished run's process can linger a moment after its last line, and Stop has to keep reaching it.
    guard runs[id]?.isOver != false else { return }
    let run = HandoffRun(repository: repository)
    runs[id] = run
    remember(repository)
    Task { await perform(id: id, run: run) }
  }

  private func perform(id: String, run: HandoffRun) async {
    let prompt: String
    do {
      let brief = try await app.tools.brief(id)
      prompt = (brief["markdown"] as? String ?? "") + "\n\n## What to do\n\nBuild this into the project in this folder."
    } catch {
      run.fail("Couldn't read the component. \(error.localizedDescription)")
      return
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    // A login shell finds `claude` wherever the person installed it, with their own PATH.
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-lc", "exec claude -p --output-format stream-json --verbose --permission-mode acceptEdits"]
    process.currentDirectoryURL = run.repository
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment.filter { $0.key != "CLAUDECODE" }
    environment["PATH"] = ([environment["PATH"] ?? "/usr/bin:/bin"] + Self.searchPath).joined(separator: ":")
    process.environment = environment
    let reader = LineReader(output.fileHandleForReading) { run.apply(HandoffEvent.read($0)) }
    let errorReader = LineReader(errors.fileHandleForReading) { run.noteError($0) }
    // Ends when the process ends. A child it left behind can hold these pipes open for much longer.
    process.terminationHandler = { [weak self] finished in
      let code = finished.terminationStatus
      let stopped = finished.terminationReason == .uncaughtSignal
      Task { @MainActor in
        // Its last line may still be in the pipe, and that line says how it ended.
        for _ in 0..<10 where !run.hasReported { try? await Task.sleep(for: .milliseconds(30)) }
        reader.stop()
        errorReader.stop()
        run.ended(status: code, stoppedByPerson: stopped)
        if let summary = run.builtSummary {
          self?.app.statuses.markBuilt(id, repository: run.repository.path, summary: summary, session: run.sessionId)
        }
      }
    }
    do {
      try process.run()
    } catch {
      run.fail("Couldn't start Claude Code. \(error.localizedDescription)")
      return
    }
    run.started(process)
    try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try? input.fileHandleForWriting.close()
  }

  func stop(_ id: String) {
    runs[id]?.stop()
  }

  /// Picks the conversation up in Terminal through a `.command` file, which needs no automation permission.
  private func resume(_ id: String) {
    let built = app.statuses.built(id)
    guard let session = runs[id]?.sessionId ?? built?.session, session.range(of: #"^[\w-]+$"#, options: .regularExpression) != nil,
      let path = runs[id]?.repository.path ?? built?.repository
    else { return }
    let folder = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    runInTerminal("cd \(folder) && exec claude --resume \(session)", named: session)
  }

  private func runInTerminal(_ command: String, named name: String) {
    let file = Paths.handoffs.appending(path: "\(name).command")
    let path = (Self.searchPath + ["$PATH"]).joined(separator: ":")
    let script = "#!/bin/zsh -l\nexport PATH=\"\(path)\"\n\(command)\n"
    do {
      try script.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      NSWorkspace.shared.open(file)
    } catch {
      app.chrome?.say(error.localizedDescription)
    }
  }

  func stopAll() {
    runs.values.forEach { $0.stop() }
  }
}
