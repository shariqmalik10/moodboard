import Foundation

/// A spring set by response and damping, the two numbers a designer tunes. Integrated in closed form, so a
/// long frame can't make it diverge, and it keeps its velocity when the target changes, so anything can be interrupted.
struct Spring {
  var value: Double
  var velocity = 0.0
  var target: Double
  var response: Double
  var damping: Double

  init(_ value: Double, response: Double = 0.4, damping: Double = 1) {
    self.value = value
    target = value
    self.response = response
    self.damping = damping
  }

  var isSettled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

  mutating func step(_ dt: Double) {
    let omega = 2 * Double.pi / response
    let offset = value - target
    if damping >= 1 {
      let decay = exp(-omega * dt)
      let b = velocity + omega * offset
      value = target + (offset + b * dt) * decay
      velocity = (b - omega * (offset + b * dt)) * decay
    } else {
      let lively = omega * (1 - damping * damping).squareRoot()
      let decay = exp(-damping * omega * dt)
      let b = (velocity + damping * omega * offset) / lively
      let (sine, cosine) = (sin(lively * dt), cos(lively * dt))
      value = target + decay * (offset * cosine + b * sine)
      velocity = decay * (lively * (b * cosine - offset * sine) - damping * omega * (offset * cosine + b * sine))
    }
    if isSettled {
      value = target
      velocity = 0
    }
  }
}

func clamp01(_ value: Double) -> Double {
  min(1, max(0, value))
}

/// Eases out without overshoot: most of the change happens early, and it arrives softly.
func easeOut(_ value: Double) -> Double {
  let t = clamp01(value)
  return 1 - (1 - t) * (1 - t) * (1 - t)
}

/// How far a tile is into the window, as a pure function of position. It doesn't depend on time,
/// so stopping stops the forming, and reversing unforms it along the same path.
struct Coverage: Equatable {
  /// 0 outside the window, 1 once the tile is fully in view.
  let p: Double
  /// The unit direction from the tile toward the middle of the window, which pieces form along.
  let dx: Double
  let dy: Double

  /// A tile taller than this share of the window counts as fully in view before all of it fits.
  static let tallestShare = 0.86

  init(tile: CGRect, view: CGRect) {
    func fraction(_ low: Double, _ high: Double, _ viewLow: Double, _ viewHigh: Double) -> Double {
      let seen = max(0, min(high, viewHigh) - max(low, viewLow))
      let full = min(high - low, (viewHigh - viewLow) * Coverage.tallestShare)
      return full > 0 ? min(1, seen / full) : 0
    }
    p = min(
      fraction(tile.minX, tile.maxX, view.minX, view.maxX),
      fraction(tile.minY, tile.maxY, view.minY, view.maxY)
    )
    let (x, y) = (view.midX - tile.midX, view.midY - tile.midY)
    let length = max((x * x + y * y).squareRoot(), 0.001)
    dx = x / length
    dy = y / length
  }
}

/// How far along one piece of a tile is. The side nearest the middle of the window forms first, and the
/// far side last, so a tile fills in behind the edge it's arriving past.
func pieceProgress(p: Double, centerX: Double, centerY: Double, coverage: Coverage, width: Double = 0.5) -> Double {
  let span = max(abs(coverage.dx) + abs(coverage.dy), 0.001)
  let toward = (centerX - 0.5) * coverage.dx + (centerY - 0.5) * coverage.dy
  let t = 0.5 - toward / span
  return clamp01((p * (1 + width) - t) / width)
}

/// Frame pacing, kept only while something is measuring it.
struct FrameStats {
  private(set) var intervals: [Double] = []
  private(set) var costs: [Double] = []
  private(set) var steps: [Double] = []
  var isRecording = false

  mutating func start() {
    intervals.removeAll(keepingCapacity: true)
    costs.removeAll(keepingCapacity: true)
    steps.removeAll(keepingCapacity: true)
    isRecording = true
  }

  mutating func record(interval: Double, cost: Double, step: Double) {
    guard isRecording else { return }
    intervals.append(interval * 1000)
    costs.append(cost * 1000)
    steps.append(step)
  }

  func summary() -> JSON {
    func spread(_ values: [Double]) -> JSON {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return ["count": 0] }
      func at(_ share: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
      return ["count": sorted.count, "p50": at(0.5), "p95": at(0.95), "p99": at(0.99), "max": sorted.last ?? 0]
    }
    return ["intervalMs": spread(intervals), "tickCostMs": spread(costs), "stepPx": spread(steps)]
  }
}
