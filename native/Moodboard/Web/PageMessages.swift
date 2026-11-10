import Foundation

/// How a stage page loads. Mirrors the flags `src/stage/main.tsx` reads from its address.
enum StageMode: String {
  /// Waits to be told to run, for a tile on the wall.
  case held
  /// Held at rest, for the plate a tile forms from.
  case still
  /// Reports how much room the component takes, for a project's component joining the wall.
  case measure
}

/// What a page tells the app. Mirrors `StageMessage` in `src/stage/protocol.ts`, plus the panel's and the runtime's own.
enum PageMessage {
  case runtimeReady
  case dials(id: String, state: Any?, byPerson: Bool)
  case ready(id: String)
  case failed(id: String, message: String)
  case measured(id: String, width: Double, height: Double, ground: String, blank: Bool)
  case escape
  /// The person took over a running component. Only the browser board uses it.
  case driving

  init?(_ json: JSON) {
    let id = json["id"] as? String ?? ""
    switch json["type"] as? String {
    case "runtime-ready": self = .runtimeReady
    case "dials": self = .dials(id: id, state: json["state"], byPerson: json["byPerson"] as? Bool ?? false)
    case "ready": self = .ready(id: id)
    case "failed": self = .failed(id: id, message: json["message"] as? String ?? "It didn't load.")
    case "measured":
      self = .measured(id: id, width: json["width"] as? Double ?? 0, height: json["height"] as? Double ?? 0, ground: json["ground"] as? String ?? "#ffffff", blank: json["blank"] as? Bool ?? true)
    case "escape": self = .escape
    case "driving": self = .driving
    default: return nil
    }
  }
}

/// What the app tells a stage page. Mirrors `HostMessage` in `src/stage/protocol.ts`.
enum HostCommand {
  case run(Bool)
  case replay
  case drive
  case reset
  case watch
  case tune(saved: JSON)

  var json: JSON {
    switch self {
    case .run(let running): ["type": "run", "run": running]
    case .replay: ["type": "replay"]
    case .drive: ["type": "drive"]
    case .reset: ["type": "reset"]
    case .watch: ["type": "watch"]
    case .tune(let saved): ["type": "tune", "saved": saved]
    }
  }
}
