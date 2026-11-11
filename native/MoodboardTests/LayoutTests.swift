import Foundation
import Testing

@testable import Moodboard

struct LayoutTests {
  private let layout = Layout(columns: [["a", "b"], ["c"]]) { $0 == "a" ? 200 : 100 }

  @Test func `every card in a rect comes back, and none outside it`() {
    let rect = CGRect(x: 0, y: 0, width: 700, height: 500)
    let cards = layout.cards(in: rect)
    #expect(!cards.isEmpty)
    #expect(cards.allSatisfy { $0.rect.intersects(rect) })
    #expect(cards.contains { $0.id == "a" })
    #expect(cards.contains { $0.id == "c" })
  }

  @Test func `keys are stable for the same spot, seen from different rects`() {
    let wide = layout.cards(in: CGRect(x: -1000, y: -1000, width: 3000, height: 3000))
    let narrow = layout.cards(in: CGRect(x: 0, y: 0, width: 320, height: 120))
    for card in narrow {
      #expect(wide.contains { $0.key == card.key && $0.y == card.y })
    }
  }

  @Test func `no two cards overlap`() {
    let cards = layout.cards(in: CGRect(x: -2000, y: -3000, width: 5000, height: 6000))
    for (index, card) in cards.enumerated() {
      for other in cards[(index + 1)...] {
        #expect(!card.rect.intersects(other.rect))
      }
    }
  }

  @Test func `a repeat of the wall never lines up with the one before`() {
    let first = layout.cards(in: CGRect(x: 0, y: 0, width: 320, height: 2000)).first { $0.id == "a" }
    let wrapped = layout.cards(in: CGRect(x: Grain.pitch * 2, y: 0, width: 320, height: 2000)).first { $0.id == "a" }
    #expect(first != nil && wrapped != nil && first?.y != wrapped?.y)
  }

  @Test func `a drop lands before the card under it`() {
    #expect(layout.slot(atX: 10, y: 20).column == 0)
    #expect(layout.slot(atX: 10, y: 20).index == 0)
    #expect(layout.slot(atX: 10, y: 150).index == 1)
    #expect(layout.slot(atX: Grain.pitch + 10, y: 20).column == 1)
  }
}

struct CoverageTests {
  private let view = CGRect(x: 0, y: 0, width: 1400, height: 900)

  @Test func `outside the window is nothing, fully inside is everything`() {
    #expect(Coverage(tile: CGRect(x: 100, y: 1000, width: 320, height: 300), view: view).p == 0)
    #expect(Coverage(tile: CGRect(x: 100, y: 100, width: 320, height: 300), view: view).p == 1)
  }

  @Test func `coverage only depends on position, and grows as a tile comes in`() {
    var last = -1.0
    for y in stride(from: 900.0, through: 600.0, by: -10) {
      let p = Coverage(tile: CGRect(x: 100, y: y, width: 320, height: 300), view: view).p
      #expect(p >= last)
      last = p
      #expect(p == Coverage(tile: CGRect(x: 100, y: y, width: 320, height: 300), view: view).p)
    }
    #expect(last == 1)
  }

  @Test func `half in, half formed, on either axis`() {
    #expect(abs(Coverage(tile: CGRect(x: 100, y: 750, width: 320, height: 300), view: view).p - 0.5) < 0.001)
    #expect(abs(Coverage(tile: CGRect(x: -160, y: 100, width: 320, height: 300), view: view).p - 0.5) < 0.001)
  }

  @Test func `a tile taller than the window can still finish`() {
    let tall = CGRect(x: 100, y: -100, width: 320, height: 1200)
    #expect(Coverage(tile: tall, view: view).p == 1)
  }

  @Test func `the side nearest the middle of the window forms first`() {
    let coverage = Coverage(tile: CGRect(x: 100, y: 750, width: 320, height: 300), view: view)
    let top = pieceProgress(p: coverage.p, centerX: 0.5, centerY: 0.1, coverage: coverage)
    let bottom = pieceProgress(p: coverage.p, centerX: 0.5, centerY: 0.9, coverage: coverage)
    #expect(top > bottom)
  }

  @Test func `every piece has finished once the tile is fully in view, and none has begun at zero`() {
    let coverage = Coverage(tile: CGRect(x: 100, y: 100, width: 320, height: 300), view: view)
    for x in stride(from: 0.0, through: 1, by: 0.25) {
      for y in stride(from: 0.0, through: 1, by: 0.25) {
        #expect(pieceProgress(p: 1, centerX: x, centerY: y, coverage: coverage) == 1)
        #expect(pieceProgress(p: 0, centerX: x, centerY: y, coverage: coverage) == 0)
      }
    }
  }
}

struct SpringTests {
  @Test func `settles on its target`() {
    var spring = Spring(0, response: 0.3)
    spring.target = 100
    for _ in 0..<240 { spring.step(1.0 / 120) }
    #expect(spring.value == 100)
    #expect(spring.isSettled)
  }

  @Test func `a critically damped spring never overshoots`() {
    var spring = Spring(0, response: 0.3)
    spring.target = 1
    for _ in 0..<240 {
      spring.step(1.0 / 120)
      #expect(spring.value <= 1.0001)
    }
  }

  @Test func `keeps its velocity when the target changes, so an interruption has no jolt`() {
    var spring = Spring(0, response: 0.3)
    spring.target = 100
    for _ in 0..<12 { spring.step(1.0 / 120) }
    let (value, velocity) = (spring.value, spring.velocity)
    spring.target = -100
    #expect(spring.value == value && spring.velocity == velocity)
    spring.step(1.0 / 120)
    #expect(abs(spring.value - value) < abs(velocity) / 120 * 1.2)
  }

  @Test func `a long frame can't blow it up`() {
    var spring = Spring(0, response: 0.1, damping: 0.7)
    spring.target = 1
    spring.step(1)
    #expect(abs(spring.value - 1) < 0.01)
  }
}

@Suite struct HandoffEventTests {
  @Test func readsTheSessionFromTheFirstLine() {
    #expect(HandoffEvent.read(#"{"type":"system","subtype":"init","session_id":"abc-1"}"#) == .started(session: "abc-1"))
  }

  @Test func namesTheFileBeingEdited() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/src/Nudge.tsx"}}]}}"#
    #expect(HandoffEvent.read(line) == .working("Editing Nudge.tsx", changed: "/repo/src/Nudge.tsx"))
  }

  @Test func aReadChangesNothing() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/a.ts"}}]}}"#
    #expect(HandoffEvent.read(line) == .working("Reading a.ts", changed: nil))
  }

  @Test func tellsSuccessFromFailure() {
    #expect(HandoffEvent.read(#"{"type":"result","subtype":"success","is_error":false,"result":"Built it.\nMore.","session_id":"s"}"#) == .finished("Built it.", session: "s"))
    #expect(HandoffEvent.read(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in","session_id":"s"}"#) == .failed("Not logged in", session: "s"))
    #expect(HandoffEvent.read(#"{"type":"result","subtype":"error_max_turns","is_error":false,"session_id":"s"}"#) == .failed("", session: "s"))
  }

  @Test func ignoresWhatItDoesntKnow() {
    #expect(HandoffEvent.read("not json") == .nothing)
    #expect(HandoffEvent.read(#"{"type":"rate_limit_event"}"#) == .nothing)
  }

  @MainActor @Test func aRunReportsChangedFilesAndKeepsItsEnding() {
    let run = HandoffRun(repository: URL(filePath: "/repo"))
    run.started(Process())
    run.apply(.working("Editing a.ts", changed: "/repo/a.ts"))
    run.apply(.working("Editing a.ts", changed: "/repo/a.ts"))
    run.apply(.finished("Built it.", session: "s"))
    #expect(run.status == "1 file changed. Built it.")
    #expect(!run.isWorking)
    // Its process is still alive, so another send waits for it.
    #expect(!run.isOver)
    #expect(run.builtSummary == nil)
    run.ended(status: 0, stoppedByPerson: false)
    #expect(run.status == "1 file changed. Built it.")
    #expect(run.isOver)
    #expect(run.builtSummary == "Built it.")
  }

  @MainActor @Test func anExpiredLoginAsksForASignIn() {
    let run = HandoffRun(repository: URL(filePath: "/repo"))
    run.apply(.failed("Failed to authenticate: OAuth session expired and could not be refreshed", session: "s"))
    #expect(run.needsSignIn)
    #expect(run.status.contains("sign in"))
  }

  @MainActor @Test func aMissingCommandIsSaidPlainly() {
    let run = HandoffRun(repository: URL(filePath: "/repo"))
    run.started(Process())
    run.noteError("zsh: command not found: claude")
    run.ended(status: 127, stoppedByPerson: false)
    #expect(run.status.contains("Couldn't find Claude Code"))
    #expect(run.isOver)
  }

  @MainActor @Test func aRunThatNeverStartedIsOver() {
    let run = HandoffRun(repository: URL(filePath: "/repo"))
    run.fail("Couldn't read the component.")
    #expect(run.isOver)
    #expect(!run.isWorking)
  }
}

@Suite struct ClaudeRegistrationTests {
  let output = """
    moodboard:
      Scope: User config (available in all your projects)
      Status: ✔ Connected
      Type: stdio
      Command: /Volumes/Work/Applications/Moodboard.app/Contents/MacOS/Moodboard
      Args: --mcp
    """

  @Test func readsTheRegisteredCommand() {
    #expect(ClaudeRegistration.command(in: output) == "/Volumes/Work/Applications/Moodboard.app/Contents/MacOS/Moodboard")
    #expect(ClaudeRegistration.command(in: "No MCP server named \"moodboard\".") == nil)
  }

  @Test func namesTheOtherAppOnlyWhenItIsntThisOne() {
    let command = "/Volumes/Work/Applications/Moodboard.app/Contents/MacOS/Moodboard"
    #expect(ClaudeRegistration.otherApp(command, this: command) == nil)
    #expect(ClaudeRegistration.otherApp(command, this: "/Applications/Moodboard.app/Contents/MacOS/Moodboard") == "/Volumes/Work/Applications/Moodboard.app")
  }
}
