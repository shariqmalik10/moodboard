import AppKit
import WebKit

/// One running component. There are only a few of these: moving a web view is cheap, but keeping one
/// alive isn't, so they follow whichever tiles are fully in view.
final class LiveStage {
  enum Phase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
  }

  let web: StageWebView
  private(set) var itemId: String?
  private(set) var phase: Phase = .idle
  private(set) var isRunning = false
  /// A person has this stage, so its script stays stopped until it goes back to the wall.
  private(set) var isHandsOn = false
  var lastUsed = 0
  /// Whoever is showing this stage. A stage without one is free to be reused.
  weak var holder: AnyObject?
  var onReady: (() -> Void)?

  init(web: StageWebView) {
    self.web = web
  }

  static func url(for id: String, flag: String) -> URL {
    if let url = ProjectCatalog.url(for: id, flag: flag) { return url }
    var components = URLComponents(url: SchemeHandler.root.appending(path: "stage.html"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "demo", value: id), URLQueryItem(name: flag, value: "1")]
    guard let url = components?.url else { fatalError("The stage's address can't be built for \(id)") }
    return url
  }

  func load(_ id: String) {
    guard itemId != id else { return }
    itemId = id
    phase = .loading
    isRunning = false
    isHandsOn = false
    web.load(URLRequest(url: Self.url(for: id, flag: "held")))
  }

  func reload() {
    guard let id = itemId else { return }
    let hadHands = isHandsOn
    itemId = nil
    load(id)
    isHandsOn = hadHands
  }

  func markReady() {
    phase = .ready
    if isHandsOn { send(#"{"type":"drive"}"#) }
    // Hot reload can load the page again by itself, and the new page waits to be told it's on show.
    else if isRunning { send(#"{"type":"run","run":true}"#) }
    onReady?()
  }
  func markFailed(_ message: String) { phase = .failed(message) }

  private func send(_ json: String) {
    web.evaluateJavaScript("window.__host && window.__host(\(json))", completionHandler: nil)
  }

  func setRunning(_ running: Bool) {
    guard phase == .ready, running != isRunning else { return }
    isRunning = running
    send(#"{"type":"run","run":\#(running)}"#)
  }

  /// Hands the component to the person, exactly as it stands. A stage still loading does this once it's ready.
  func handOver() {
    isHandsOn = true
    if phase == .ready { send(#"{"type":"drive"}"#) }
  }

  func startOver() {
    if phase == .ready { send(#"{"type":"reset"}"#) }
  }

  /// Plays the script once, and any movement of the person's pointer over it ends it early.
  func watch() {
    if phase == .ready { send(#"{"type":"watch"}"#) }
  }

  func backToLoop() {
    isHandsOn = false
    guard phase == .ready else { return }
    isRunning = true
    send(#"{"type":"replay"}"#)
  }

  func tune(saved: JSON) {
    guard phase == .ready, let data = try? JSONSerialization.data(withJSONObject: saved), let text = String(data: data, encoding: .utf8) else { return }
    send(#"{"type":"tune","saved":\#(text)}"#)
  }

  /// Shows the component's crop at this scale. Page zoom keeps the real layout size for its media
  /// queries, while WebKit draws at the size on screen, so text stays sharp at any scale.
  func present(viewport: Size, crop: Crop, scale: Double) {
    web.pageZoom = scale
    web.frame = CGRect(x: -crop.x * scale, y: -crop.y * scale, width: viewport.w * scale, height: viewport.h * scale)
  }
}

final class LivePool {
  private let host: WebHost
  private let backstage: NSView
  private var stages: [LiveStage] = []
  private var clock = 0

  /// Enough for every tile that can be fully in view on a large display at normal zoom.
  static let budget = 12

  init(host: WebHost, backstage: NSView) {
    self.host = host
    self.backstage = backstage
  }

  var count: Int { stages.count }
  var liveCount: Int { stages.filter { $0.holder != nil }.count }
  var runningCount: Int { stages.filter(\.isRunning).count }

  func stage(of web: WKWebView?) -> LiveStage? { stages.first { $0.web === web } }

  var all: [LiveStage] { stages }

  func stages(showing id: String) -> [LiveStage] { stages.filter { $0.itemId == id } }

  /// Prefers a stage already showing this component. Otherwise it takes the one idle the longest.
  func acquire(_ id: String, for holder: AnyObject) -> LiveStage? {
    clock += 1
    let idle = stages.filter { $0.holder == nil }
    let stage: LiveStage
    if let same = idle.first(where: { $0.itemId == id }) {
      stage = same
    } else if stages.count < Self.budget {
      stage = LiveStage(web: host.makeWebView())
      stages.append(stage)
    } else if let oldest = idle.min(by: { $0.lastUsed < $1.lastUsed }) {
      stage = oldest
    } else {
      return nil
    }
    stage.holder = holder
    stage.lastUsed = clock
    stage.load(id)
    return stage
  }

  func release(_ stage: LiveStage) {
    if stage.isHandsOn { stage.backToLoop() }
    stage.setRunning(false)
    stage.holder = nil
    stage.onReady = nil
    clock += 1
    stage.lastUsed = clock
    stage.web.isInteractive = false
    backstage.addSubview(stage.web)
  }
}
