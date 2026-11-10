import Foundation

/// Every column is this wide, and the wall repeats every N columns, forever.
enum Grain {
  static let cardWidth = 320.0
  static let gap = 28.0
  static let pitch = cardWidth + gap
  /// Pushes each column's start down a different amount, so the tops never line up into a grid.
  static let stagger: [Double] = [0, 96, 28, 148, 56, 120, 12, 84]
  /// Each repeat of the whole wall slides this far, so a repeat never reads as the same picture.
  static let wrapShift = 317.0
}

/// One card somewhere on the endless wall. Its key survives a reflow, so its live view stays alive.
struct Instance: Equatable {
  struct Key: Hashable {
    let id: String
    let column: Int
    let repeatIndex: Int
  }

  let key: Key
  let x: Double
  let y: Double
  let h: Double
  /// How far the card is scaled down from its size on the wall.
  var scale = 1.0
  /// The cell the card stands in, in the views that give each card a cell of its own.
  var cell: CGRect?

  var id: String { key.id }
  var rect: CGRect { CGRect(x: x, y: y, width: Grain.cardWidth * scale, height: h) }
}

private func floorMod(_ value: Int, _ by: Int) -> Int {
  ((value % by) + by) % by
}

private func floorDiv(_ value: Int, _ by: Int) -> Int {
  Int((Double(value) / Double(by)).rounded(.down))
}

struct Layout {
  private struct Card {
    let id: String
    let y: Double
    let h: Double
  }

  private struct Column {
    let cards: [Card]
    let height: Double
    let stagger: Double
  }

  private let columns: [Column]

  init(columns lists: [[String]], heightOf: (String) -> Double) {
    columns = lists.filter { !$0.isEmpty }.enumerated().map { at, list in
      var y = 0.0
      let cards = list.map { id -> Card in
        let h = heightOf(id)
        defer { y += h + Grain.gap }
        return Card(id: id, y: y, h: h)
      }
      return Column(cards: cards, height: y, stagger: Grain.stagger[at % Grain.stagger.count])
    }
  }

  /// How far to look to be sure of finding a repeat of every card.
  var span: Double {
    max(Double(columns.count) * Grain.pitch, (columns.map(\.height).max() ?? 0) + abs(Grain.wrapShift))
  }

  private func column(at cx: Int) -> (column: Column, origin: Double) {
    let column = columns[floorMod(cx, columns.count)]
    return (column, column.stagger + Double(floorDiv(cx, columns.count)) * Grain.wrapShift)
  }

  func cards(in rect: CGRect) -> [Instance] {
    guard !columns.isEmpty else { return [] }
    var found: [Instance] = []
    var cx = Int((rect.minX / Grain.pitch).rounded(.down))
    while Double(cx) * Grain.pitch < rect.maxX {
      let x = Double(cx) * Grain.pitch
      if x + Grain.cardWidth >= rect.minX {
        let (column, origin) = column(at: cx)
        var k = Int(((rect.minY - origin) / column.height).rounded(.down)) - 1
        while origin + Double(k) * column.height < rect.maxY {
          for card in column.cards {
            let y = origin + Double(k) * column.height + card.y
            if y < rect.maxY, y + card.h > rect.minY {
              found.append(Instance(key: .init(id: card.id, column: cx, repeatIndex: k), x: x, y: y, h: card.h))
            }
          }
          k += 1
        }
      }
      cx += 1
    }
    return found
  }

  /// Where a card dropped at this point of the wall belongs: which column, and before which card.
  func slot(atX worldX: Double, y worldY: Double) -> (column: Int, index: Int) {
    let cx = Int(((worldX + Grain.gap / 2) / Grain.pitch).rounded(.down))
    let (column, origin) = column(at: cx)
    let wrapped = (worldY - origin).truncatingRemainder(dividingBy: column.height)
    let inRepeat = wrapped < 0 ? wrapped + column.height : wrapped
    let index = column.cards.firstIndex { inRepeat < $0.y + $0.h / 2 } ?? column.cards.count
    return (floorMod(cx, columns.count), index)
  }
}
