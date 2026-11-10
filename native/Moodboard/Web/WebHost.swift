import AppKit
import WebKit

/// Serves the bundled web components under one origin, plus the few things the app itself knows.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "moodboard"
  static let root = URL(string: "moodboard://app/")!

  private let bundle: URL
  private var running = Set<ObjectIdentifier>()
  /// A connected project's component is described by its own server.
  var projectRecord: ((String) async -> Data?)?

  override init() {
    guard let resources = Bundle.main.resourceURL else { fatalError("The app has no resources folder") }
    bundle = resources.appending(path: "web", directoryHint: .isDirectory)
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
    if url.path == "/api/component", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value, ProjectCatalog.isProjectId(id) {
      let key = ObjectIdentifier(task)
      running.insert(key)
      Task {
        let data = await projectRecord?(id) ?? Data("null".utf8)
        guard running.remove(key) != nil else { return }
        respond(task, url: url, data: data, status: 200, mime: "application/json")
      }
      return
    }
    if url.path.hasPrefix("/api/") {
      return respond(task, url: url, data: api(url), status: 200, mime: "application/json")
    }
    let file = bundle.appending(path: String(url.path.dropFirst()))
    guard file.standardizedFileURL.path.hasPrefix(bundle.standardizedFileURL.path) else {
      return respond(task, url: url, data: Data(), status: 403, mime: "text/plain")
    }
    let id = ObjectIdentifier(task)
    running.insert(id)
    Task {
      let data = await Self.read(file)
      guard running.remove(id) != nil else { return }
      if let data {
        respond(task, url: url, data: data, status: 200, mime: Self.mime(of: file))
      } else {
        respond(task, url: url, data: Data(), status: 404, mime: "text/plain")
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    running.remove(ObjectIdentifier(task))
  }

  private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, status: Int, mime: String) {
    let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private func api(_ url: URL) -> Data {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let id = query.first { $0.name == "id" }?.value ?? ""
    switch url.path {
    case "/api/dials": return DialState.read(id) ?? Data("null".utf8)
    case "/api/component": return ComponentLibrary.recordData(id) ?? Data("null".utf8)
    default: return Data("null".utf8)
    }
  }

  private nonisolated static func mime(of file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json": "application/json"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "webp": "image/webp"
    case "woff2": "font/woff2"
    case "woff": "font/woff"
    case "ttf": "font/ttf"
    case "otf": "font/otf"
    default: "application/octet-stream"
    }
  }

  private nonisolated static func read(_ file: URL) async -> Data? {
    await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
  }

  /// Names the bundled build, so plates baked from an older build are never shown.
  static func buildKey() -> String {
    guard let resources = Bundle.main.resourceURL else { return "none" }
    let assets = resources.appending(path: "web/assets")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).sorted().joined(separator: "\n")
    return stableHash(Data(names.utf8))
  }
}

/// What the pages say, sorted by who said it.
final class WebBridge: NSObject, WKScriptMessageHandler {
  var onMessage: ((WKWebView?, JSON) -> Void)?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? JSON else { return }
    onMessage?(message.webView, body)
  }
}

/// A web view on the wall ignores the pointer. The canvas handles it until the tile is opened.
final class StageWebView: WKWebView {
  var isInteractive = false

  override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }
  override func mouseMoved(with event: NSEvent) { if isInteractive { super.mouseMoved(with: event) } }
  override func mouseEntered(with event: NSEvent) { if isInteractive { super.mouseEntered(with: event) } }
  override func mouseExited(with event: NSEvent) { if isInteractive { super.mouseExited(with: event) } }
  override func cursorUpdate(with event: NSEvent) { if isInteractive { super.cursorUpdate(with: event) } }
  override var acceptsFirstResponder: Bool { isInteractive }
}

/// Makes the app's web views, all sharing one URL scheme handler and one message bridge.
final class WebHost {
  let bridge = WebBridge()
  let scheme = SchemeHandler()

  func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(scheme, forURLScheme: SchemeHandler.scheme)
    configuration.userContentController.add(bridge, name: "moodboard")
    configuration.suppressesIncrementalRendering = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    return configuration
  }

  func makeWebView(frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 320)) -> StageWebView {
    let web = StageWebView(frame: frame, configuration: makeConfiguration())
    web.allowsMagnification = false
    web.allowsBackForwardNavigationGestures = false
    #if DEBUG
      // A take parks the window off screen, and WebKit stops drawing a page whose window it thinks is covered.
      if UserDefaults.standard.bool(forKey: "MoodboardRecording"), web.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
        web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
      }
    #endif
    return web
  }
}

/// A page with no window of its own that answers questions the web code alone can answer: what
/// components exist, and what CSS a tune produces. It holds a whole web process, and the questions come
/// in bursts, so it opens when asked and closes after a quiet minute. It keeps nothing between questions.
final class Runtime {
  private let host: WebHost
  private let backstage: NSView
  private var web: StageWebView?
  private var isReady = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var busy = 0
  private var idle: Task<Void, Never>?

  static let closesAfter: Duration = .seconds(60)

  init(host: WebHost, backstage: NSView) {
    self.host = host
    self.backstage = backstage
  }

  func markReady() {
    isReady = true
    waiting.forEach { $0.resume() }
    waiting = []
  }

  func start() async {
    if web == nil {
      let web = host.makeWebView()
      backstage.addSubview(web)
      self.web = web
      isReady = false
      web.load(URLRequest(url: SchemeHandler.root.appending(path: "runtime.html")))
    }
    guard !isReady else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Data {
    busy += 1
    idle?.cancel()
    defer {
      busy -= 1
      if busy == 0 { closeLater() }
    }
    await start()
    guard let web else { throw CocoaError(.featureUnsupported) }
    return try await web.callJSON(body, arguments)
  }

  private func closeLater() {
    idle = Task { [weak self] in
      try? await Task.sleep(for: Self.closesAfter)
      guard !Task.isCancelled, let self, self.busy == 0, self.isReady else { return }
      self.web?.removeFromSuperview()
      self.web = nil
      self.isReady = false
    }
  }

  func catalog() async throws -> Catalog {
    try JSONDecoder().decode(Catalog.self, from: try await call("return window.__runtime.catalog()"))
  }

  /// The dial panel's config, resolved values and generated CSS for one tune.
  func tuned(_ id: String) async throws -> JSON {
    let data = try await call("return await window.__runtime.tuned(id, saved)", ["id": id, "saved": DialState.saved(id)])
    return try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
  }
}

extension WKWebView {
  /// Runs a script body and hands back what it returned as JSON bytes.
  func callJSON(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          do {
            continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
          } catch {
            continuation.resume(throwing: error)
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
