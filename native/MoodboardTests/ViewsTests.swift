import Foundation
import Testing

@testable import Moodboard

struct ViewsTests {
  private let height: (String) -> Double = { $0.hasPrefix("tall") ? 400 : 120 }

  @Test func `a project of a few things never stands a tile over itself`() {
    let columns = Layout.columns(for: ["a", "b", "c"], maxColumns: 7, heightOf: height)
    #expect(columns.allSatisfy { Set($0) == ["a", "b", "c"] })
    #expect(Set(columns.compactMap(\.first)) == ["a", "b", "c"])
    let cards = Layout(columns: columns, heightOf: height).cards(in: CGRect(x: -2000, y: -2000, width: 4000, height: 4000))
    for (index, card) in cards.enumerated() {
      for other in cards[(index + 1)...] {
        #expect(!card.rect.intersects(other.rect))
      }
    }
  }

  @Test func `a bigger project shows each thing once, in columns of about the same height`() {
    let ids = (0..<26).map { $0 % 4 == 0 ? "tall\($0)" : "short\($0)" }
    let columns = Layout.columns(for: ids, maxColumns: 7, heightOf: height)
    #expect(columns.count <= 7)
    #expect(columns.flatMap { $0 }.sorted() == ids.sorted())
    let heights = columns.map { $0.reduce(0) { $0 + height($1) + Grain.gap } }
    #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 400 + Grain.gap)
  }

  @Test func `a filter with nothing to show makes an empty wall`() {
    let columns = Layout.columns(for: [], maxColumns: 7, heightOf: height)
    #expect(columns.isEmpty)
    #expect(Layout(columns: columns, heightOf: height).cards(in: CGRect(x: 0, y: 0, width: 800, height: 800)).isEmpty)
  }

  private func grid(width: Double = 1440) -> GridLayout {
    GridLayout(
      sections: [
        .init(title: "Greenhouse", ids: (0..<9).map { "tall\($0)" }),
        .init(title: "Empty", ids: []),
        .init(title: "Tidepool", ids: (0..<7).map { "short\($0)" }),
      ],
      width: width,
      heightOf: height
    )
  }

  private var everything: CGRect { CGRect(x: -100, y: -100, width: 5000, height: 20000) }

  @Test func `the grid shows every card once, inside its cell, with no overlaps`() {
    let cards = grid().cards(in: everything)
    #expect(cards.count == 16)
    #expect(Set(cards.map(\.id)).count == 16)
    #expect(cards.allSatisfy { card in card.cell.map { $0.insetBy(dx: -0.01, dy: -0.01).contains(card.rect) } == true })
    let wells = cards.compactMap(\.cell)
    #expect(Set(wells.map(\.size.width)).count == 1)
    #expect(Set(wells.map(\.size.height)).count == 1)
    for (index, card) in cards.enumerated() {
      for other in cards[(index + 1)...] {
        #expect(!card.rect.intersects(other.rect))
      }
    }
  }

  @Test func `the grid heads each project that has something, and stays inside the window`() {
    for width in [320.0, 900, 1440, 2600] {
      let layout = grid(width: width)
      #expect(layout.headings.map(\.title) == ["Greenhouse", "Tidepool"])
      let cards = layout.cards(in: everything)
      if width >= GridLayout.Density.medium.cellWidth + 64 {
        #expect(cards.allSatisfy { $0.cell.map { $0.minX >= 0 && $0.maxX <= width } == true })
      }
    }
  }

  @Test func `the grid only hands back the cards in view`() {
    let view = CGRect(x: 0, y: 0, width: 1440, height: 500)
    let cards = grid().cards(in: view)
    #expect(!cards.isEmpty)
    #expect(cards.count < 16)
    #expect(cards.allSatisfy { $0.rect.intersects(view) })
  }

  @Test func `the grid has ends, and a short grid does not scroll`() {
    let layout = grid()
    let limits = layout.scrollLimits(viewHeight: 800)
    #expect(limits?.upperBound == 0)
    #expect((limits?.lowerBound ?? 0) == 800 - layout.span)
    #expect(layout.scrollLimits(viewHeight: layout.span + 500) == 0...0)
    #expect(!layout.isEndless)
    #expect(Layout(columns: [["a"]], heightOf: height).isEndless)
  }

  @Test func `the grid fills the window, and a larger density means fewer, bigger cells`() {
    let sections = [GridLayout.Section(title: "Greenhouse", ids: (0..<12).map { "short\($0)" })]
    let wells = { (density: GridLayout.Density) in
      GridLayout(sections: sections, width: 1440, density: density, heightOf: height).cards(in: everything).compactMap(\.cell)
    }
    #expect((wells(.small).first?.width ?? 0) < (wells(.medium).first?.width ?? 0))
    #expect((wells(.medium).first?.width ?? 0) < (wells(.large).first?.width ?? 0))
    for density in GridLayout.Density.allCases {
      let cells = wells(density)
      #expect(abs((cells.map(\.maxX).max() ?? 0) - (1440 - 32)) < 0.01)
      #expect(abs((cells.map(\.minX).min() ?? 0) - 32) < 0.01)
    }
  }

  @Test func `a heading counts what's under it`() {
    #expect(grid().headings.map(\.count) == [9, 7])
  }
}

struct StatusTests {
  private let item = Item(row: CatalogRow(id: "greenhouse/rail", project: "greenhouse", title: "Rail", viewport: Size(w: 100, h: 100), crop: Crop(x: 0, y: 0, w: 100, h: 100), dark: false, ground: "#fff"))

  @Test func `a tune needs building until it is built, and again once it changes`() {
    #expect(!ComponentStatus().needsBuilding)
    #expect(ComponentStatus().mark == nil)
    let tuned = ComponentStatus(tuned: 3)
    #expect(tuned.needsBuilding)
    #expect(tuned.mark?.label == "3 tuned")
    let built = ComponentStatus(tuned: 3, build: .built)
    #expect(!built.needsBuilding)
    #expect(built.mark?.label == "Built")
    let moved = ComponentStatus(tuned: 3, build: .changedSince)
    #expect(moved.needsBuilding)
    #expect(moved.mark?.label == "Changed since built")
    #expect(ComponentStatus(tuned: 0, build: .changedSince).needsBuilding)
  }

  @Test func `a change in Paper says so before anything else`() {
    #expect(ComponentStatus(tuned: 3, paper: .changed, build: .built).mark?.label == "Paper changed")
    #expect(ComponentStatus(tuned: 3, paper: .current).mark?.label == "3 tuned")
    #expect(ComponentStatus(paper: .missing).mark == nil)
  }

  @Test func `a search and a status both have to match`() {
    let noted = ComponentStatus(hasNote: true)
    #expect(Refinement().matches(item, ComponentStatus()))
    #expect(Refinement(query: "  rAi ").matches(item, ComponentStatus()))
    #expect(!Refinement(query: "sheet").matches(item, ComponentStatus()))
    #expect(Refinement(query: "rail", attention: .notes).matches(item, noted))
    #expect(!Refinement(query: "rail", attention: .notes).matches(item, ComponentStatus()))
    #expect(!Refinement(query: "sheet", attention: .notes).matches(item, noted))
    #expect(!Refinement(query: "   ").isActive)
  }

  @Test func `each kind of dial value reads plainly`() {
    #expect(DialChange.show(17 as NSNumber) == "17")
    #expect(DialChange.show(0.985 as NSNumber) == "0.985")
    #expect(DialChange.show(true as NSNumber) == "on")
    #expect(DialChange.show("#fff") == "#fff")
    #expect(DialChange.show(["type": "easing", "duration": 0.28] as JSON) == "ease 0.28 s")
    #expect(DialChange.show(["type": "spring", "visualDuration": 0.5] as JSON) == "spring 0.5 s")
    #expect(DialChange.show(["type": "spring", "stiffness": 200, "damping": 25] as JSON) == "spring 200/25")
    #expect(DialChange.show(["other": 1] as JSON) == "edited")
  }
}

struct ProjectSyncTests {
  @Test func `a row that fills any width gets a narrower page, so it isn't a sliver on the wall`() {
    let row = ProjectSizing.viewport(width: 664, height: 56)
    #expect(row.w == 480)
    #expect(row.h / row.w >= 0.5)
  }

  @Test func `a tall component is cut off rather than stretching the wall`() {
    let page = ProjectSizing.viewport(width: 664, height: 4013)
    #expect(page.w == 712)
    #expect(page.h == 712 * 1.5)
  }

  @Test func `a small card keeps its padding`() {
    let card = ProjectSizing.viewport(width: 320, height: 300)
    #expect(card.w == 368)
    #expect(card.h == 348)
  }

  @Test @MainActor func `sample props stay in the app and everything else goes to the source`() {
    let (samples, source) = ProjectSync.split(["Sample props.title": "A", "article.radius": 18, "reset": true])
    #expect(samples.keys.sorted() == ["Sample props.title"])
    #expect(source.keys.sorted() == ["article.radius"])
  }

  @Test func `a project's component shows what it wrote and never asks to be built`() {
    let status = ComponentStatus(written: 2)
    #expect(status.mark?.label == "2 written")
    #expect(!status.needsBuilding)
  }
}
