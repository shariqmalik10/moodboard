import Foundation

/// One component as the project's server reports it.
struct FoundComponent: Codable, Equatable {
  var id: String
  var title: String
  var file: String
  var exportName: String
  var hash: String
}

/// One connected project's dev server, which the app starts and stops. It runs on this Mac only.
final class ProjectServer {
  enum Event {
    case listening(port: Int, slug: String)
    case components(items: [FoundComponent], bySelf: Bool)
    case stopped(reason: String)
  }

  private struct Line: Decodable {
    var type: String
    var port: Int?
    var slug: String?
    var items: [FoundComponent]?
    var bySelf: Bool?
    var message: String?
  }

  private static let searchPath = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { NSString(string: $0).expandingTildeInPath }

  let root: URL
  private let slug: String
  /// Without this, any web page open on this Mac could ask the server to write to the project.
  private let token = UUID().uuidString
  private var process: Process?
  private var input: Pipe?
  private var readers: [LineReader] = []
  private var lastError: String?
  private var isStopping = false
  private(set) var port: Int?
  var onEvent: ((Event) -> Void)?

  init(root: URL, slug: String) {
    self.root = root
    self.slug = slug
  }

  func start() {
    guard process == nil, let resources = Bundle.main.resourceURL else { return }
    let sync = resources.appending(path: "sync", directoryHint: .isDirectory)
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    // A login shell finds `node` wherever the person installed it. Tailwind looks for its files from the working directory.
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-lc", "exec node \"$0\" \"$@\"", sync.appending(path: "server.mjs").path, "--root", root.path, "--support", Paths.support.path, "--assets", sync.appending(path: "assets").path, "--slug", slug]
    process.currentDirectoryURL = root
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = ([environment["PATH"] ?? "/usr/bin:/bin"] + Self.searchPath).joined(separator: ":")
    environment["MOODBOARD_TOKEN"] = token
    process.environment = environment
    readers = [
      LineReader(output.fileHandleForReading) { [weak self] in self?.read($0) },
      LineReader(errors.fileHandleForReading) { [weak self] in self?.lastError = $0 },
    ]
    process.terminationHandler = { [weak self] finished in
      let code = finished.terminationStatus
      Task { @MainActor in self?.ended(code: code) }
    }
    do {
      try process.run()
    } catch {
      onEvent?(.stopped(reason: "Couldn't start the project's server. \(error.localizedDescription)"))
      return
    }
    self.process = process
    self.input = input
  }

  /// The server leaves when its input closes, so it goes with the app even after a crash.
  func stop() {
    isStopping = true
    try? input?.fileHandleForWriting.close()
    process?.terminate()
    process = nil
    port = nil
  }

  private func ended(code: Int32) {
    readers.forEach { $0.stop() }
    readers = []
    process = nil
    port = nil
    guard !isStopping else { return }
    let reason = code == 127 ? "Couldn't find Node. Moodboard runs each project with the `node` on your PATH." : lastError ?? "Its server stopped with code \(code)."
    onEvent?(.stopped(reason: reason))
  }

  private func read(_ text: String) {
    guard let line = try? JSONDecoder().decode(Line.self, from: Data(text.utf8)) else { return }
    switch line.type {
    case "listening":
      port = line.port
      if let port = line.port, let slug = line.slug { onEvent?(.listening(port: port, slug: slug)) }
    case "components":
      onEvent?(.components(items: line.items ?? [], bySelf: line.bySelf ?? false))
    case "failed":
      lastError = line.message
    default:
      break
    }
  }

  private func request(_ path: String, body: Data? = nil) async throws -> Data {
    guard let port, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw ToolError("The project's server isn't running.") }
    var request = URLRequest(url: url)
    request.setValue(token, forHTTPHeaderField: "x-moodboard")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
    }
    return try await URLSession.shared.data(for: request).0
  }

  /// A component's panel, with each dial at what the source says now.
  func dials(id: String) async throws -> Data {
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "id", value: id)]
    return try await request("/__moodboard/dials?\(query.percentEncodedQuery ?? "")")
  }

  func write(id: String, values: JSON) async throws -> JSON {
    let body = try JSONSerialization.data(withJSONObject: ["id": id, "values": values] as JSON)
    return try JSONSerialization.jsonObject(with: try await request("/__moodboard/write", body: body)) as? JSON ?? [:]
  }
}
