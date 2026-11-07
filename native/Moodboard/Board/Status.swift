import AppKit

/// How a design on the wall compares with the same frame in Paper right now.
enum PaperState: String, Equatable {
  case current
  case changed
  case missing
}

/// What the person has handed to Claude Code, and the tune and design it was built from.
struct Built: Codable, Equatable {
  var at: Date
  var repository: String?
  var summary: String?
  var session: String?
  var tune: String
  var design: String?
}

/// What the person has said about a component, kept apart from the board so a filter or an import never touches it.
struct Annotation: Codable, Equatable {
  var note: String?
  var built: Built?
  /// Dials the person had tuned that the last update from Paper no longer has.
  var lostTune: [String]?

  var isEmpty: Bool { note == nil && built == nil && lostTune == nil }
}

/// Where a component stands in the loop from Paper to code. Everything here is worked out from the facts.
struct ComponentStatus: Equatable {
  enum Build: Equatable {
    case never
    case built
    case changedSince
  }

  enum Tone {
    case attention
    case accent
    case done
  }

  var tuned = 0
  var hasNote = false
  var paper: PaperState?
  var build = Build.never
  /// Dials on a connected project's component that have edited its source this session.
  var written = 0

  var needsBuilding: Bool { build == .changedSince || (build == .never && tuned > 0) }

  /// The one thing most worth saying about this component, if there is anything.
  var mark: (label: String, tone: Tone)? {
    if written > 0 { return ("\(written) written", .done) }
    if paper == .changed { return ("Paper changed", .attention) }
    if build == .changedSince { return ("Changed since built", .attention) }
    if tuned > 0, build == .never { return ("\(tuned) tuned", .accent) }
    if build == .built { return ("Built", .done) }
    return nil
  }

  func matches(_ attention: Attention) -> Bool {
    switch attention {
    case .toBuild: needsBuilding
    case .notes: hasNote
    case .paperChanged: paper == .changed
    case .built: build == .built
    }
  }
}

/// The questions worth asking of the whole board while iterating.
enum Attention: String, CaseIterable, Identifiable {
  case toBuild
  case notes
  case paperChanged
  case built

  var id: String { rawValue }

  var title: String {
    switch self {
    case .toBuild: "To build"
    case .notes: "Notes"
    case .paperChanged: "Paper changed"
    case .built: "Built"
    }
  }

  var symbol: String {
    switch self {
    case .toBuild: "slider.horizontal.3"
    case .notes: "text.bubble"
    case .paperChanged: "arrow.triangle.2.circlepath"
    case .built: "checkmark"
    }
  }
}

/// What narrows Grid and List beyond the project. The Wall stays whole.
struct Refinement: Equatable {
  var query = ""
  var attention: Attention?

  var isActive: Bool { attention != nil || !trimmed.isEmpty }
  private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  func matches(_ item: Item, _ status: ComponentStatus) -> Bool {
    if let attention, !status.matches(attention) { return false }
    return trimmed.isEmpty || item.title.localizedCaseInsensitiveContains(trimmed)
  }
}

/// One dial the person moved, with what it was.
struct DialChange: Identifiable {
  let dial: String
  let from: Any
  let to: Any

  var id: String { dial }
  var label: String { dial.split(separator: ".").joined(separator: " · ") }
  var fromText: String { Self.show(from) }
  var toText: String { Self.show(to) }
  var line: String { "\(dial): \(fromText) → \(toText)" }

  init?(_ json: JSON) {
    guard let dial = json["dial"] as? String else { return nil }
    self.dial = dial
    from = json["from"] ?? NSNull()
    to = json["to"] ?? NSNull()
  }

  static func show(_ value: Any) -> String {
    switch value {
    case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): flag.boolValue ? "on" : "off"
    case let number as NSNumber: number.doubleValue.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    case let text as String: text
    case is NSNull: "none"
    case let curve as JSON: showCurve(curve)
    default: "edited"
    }
  }

  /// A motion dial in a few words: its kind, and how long or how stiff.
  private static func showCurve(_ curve: JSON) -> String {
    let number = { (key: String) in (curve[key] as? NSNumber).map { show($0) } }
    switch curve["type"] as? String {
    case "easing": return number("duration").map { "ease \($0) s" } ?? "ease"
    case "spring":
      if let time = number("visualDuration") { return "spring \(time) s" }
      if let stiffness = number("stiffness"), let damping = number("damping") { return "spring \(stiffness)/\(damping)" }
      return "spring"
    default: return "edited"
    }
  }
}

/// Keeps each component's place in the loop, and tells the views when it moves.
final class StatusStore {
  private unowned let runtime: Runtime
  private var annotations: [String: Annotation]
  private var tuneKeys: [String: String] = [:]
  private var changeLists: [String: [DialChange]] = [:]
  private var writes: [String: [DialChange]] = [:]
  private var paperStates: [String: PaperState] = [:]
  private var pending: [String: Task<Void, Never>] = [:]
  private var writing: Task<Void, Never>?
  var onChange: ((String?) -> Void)?

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  init(runtime: Runtime) {
    self.runtime = runtime
    annotations = (try? Data(contentsOf: Paths.notes)).flatMap { try? Self.decoder.decode([String: Annotation].self, from: $0) } ?? [:]
  }

  func status(_ id: String) -> ComponentStatus {
    // A connected project's dials are already in its source, so there's nothing waiting to be built.
    if ProjectCatalog.isProjectId(id) { return ComponentStatus(hasNote: annotations[id]?.note != nil, written: writes[id]?.count ?? 0) }
    var status = ComponentStatus(tuned: changeLists[id]?.count ?? 0, hasNote: annotations[id]?.note != nil, paper: paperStates[id])
    if let built = annotations[id]?.built {
      let isSame = built.tune == (tuneKeys[id] ?? Self.untuned) && built.design == Self.design(of: id)
      status.build = isSame ? .built : .changedSince
    }
    return status
  }

  func changes(_ id: String) -> [DialChange] { (changeLists[id] ?? []) + (writes[id] ?? []) }

  func setWrites(_ id: String, _ changes: [DialChange]) {
    writes[id] = changes
    onChange?(id)
  }
  func note(_ id: String) -> String { annotations[id]?.note ?? "" }
  func built(_ id: String) -> Built? { annotations[id]?.built }
  func lostTune(_ id: String) -> [String] { annotations[id]?.lostTune ?? [] }

  private static let untuned = "[]"

  private static func design(of id: String) -> String? {
    ComponentLibrary.record(id).map { stableHash(Data($0.jsx.utf8)) }
  }

  // MARK: What the dials say

  func loadTunes(ids: [String]) async {
    var saved: JSON = [:]
    for id in ids where DialState.read(id) != nil { saved[id] = DialState.saved(id) }
    guard !saved.isEmpty, let data = try? await runtime.call("return await window.__runtime.tuneSummaries(saved)", ["saved": saved]),
      let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: JSON]
    else { return }
    for (id, summary) in found { apply(summary, to: id) }
    onChange?(nil)
  }

  /// Asks again a moment after the dials stop moving, since a dragged slider saves on every step.
  func tuneChanged(_ id: String) {
    pending[id]?.cancel()
    pending[id] = Task {
      try? await Task.sleep(for: .milliseconds(90))
      guard !Task.isCancelled else { return }
      await refresh(id)
    }
  }

  func refresh(_ id: String) async {
    let saved = DialState.saved(id)
    guard let data = try? await runtime.call("return (await window.__runtime.tuneSummaries({ [id]: saved }))[id]", ["id": id, "saved": saved]),
      let summary = (try? JSONSerialization.jsonObject(with: data)) as? JSON
    else { return }
    apply(summary, to: id)
    onChange?(id)
  }

  private func apply(_ summary: JSON, to id: String) {
    tuneKeys[id] = summary["key"] as? String
    changeLists[id] = (summary["changes"] as? [JSON] ?? []).compactMap(DialChange.init)
  }

  // MARK: What the person said

  func setNote(_ id: String, _ text: String) {
    let hadNote = annotations[id]?.note != nil
    edit(id) { $0.note = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text }
    let hasNote = annotations[id]?.note != nil
    saveSoon()
    if hadNote != hasNote { onChange?(id) }
  }

  func markBuilt(_ id: String, repository: String?, summary: String?, session: String?) {
    edit(id) {
      $0.built = Built(at: .now, repository: repository, summary: summary, session: session, tune: tuneKeys[id] ?? Self.untuned, design: Self.design(of: id))
      $0.note = nil
    }
    save()
    onChange?(id)
  }

  func clearBuilt(_ id: String) {
    edit(id) { $0.built = nil }
    save()
    onChange?(id)
  }

  func recordLostTune(_ id: String, _ dials: [String]) {
    edit(id) { $0.lostTune = dials.isEmpty ? nil : dials }
    save()
    onChange?(id)
  }

  func forget(_ id: String) {
    annotations[id] = nil
    tuneKeys[id] = nil
    changeLists[id] = nil
    writes[id] = nil
    paperStates[id] = nil
    save()
  }

  func setPaper(_ id: String, _ state: PaperState?) {
    guard paperStates[id] != state else { return }
    paperStates[id] = state
    onChange?(id)
  }

  private func edit(_ id: String, _ change: (inout Annotation) -> Void) {
    var annotation = annotations[id] ?? Annotation()
    change(&annotation)
    annotations[id] = annotation.isEmpty ? nil : annotation
  }

  private func saveSoon() {
    writing?.cancel()
    writing = Task {
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { save() }
    }
  }

  func save() {
    writing?.cancel()
    writing = nil
    if let data = try? Self.encoder.encode(annotations) { try? data.write(to: Paths.notes, options: .atomic) }
  }
}
