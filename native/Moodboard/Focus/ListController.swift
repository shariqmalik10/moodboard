import AppKit
import SwiftUI

@Observable
final class ListModel {
  struct Row: Identifiable {
    let id: String
    let title: String
    let picture: CGImage?
    let ground: NSColor
    let status: ComponentStatus
  }

  struct Section: Identifiable {
    let id: String
    let title: String
    let rows: [Row]
  }

  var sections: [Section] = []
  var selection: String?
  /// Bumped to put the keyboard on the rows.
  var focusRequest = 0

  var ids: [String] { sections.flatMap(\.rows).map(\.id) }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

private struct ListRow: View {
  let row: ListModel.Row
  let isSelected: Bool
  let onPress: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onPress) {
      HStack(spacing: 10) {
        ZStack {
          Color(nsColor: row.ground)
          if let picture = row.picture {
            Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
          }
        }
        .frame(width: 44, height: 33)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))

        VStack(alignment: .leading, spacing: 1) {
          Text(row.title).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).lineLimit(1)
          if let mark = row.status.mark {
            Text(mark.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: mark.tone.color)).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if row.status.hasNote {
          Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityLabel("Has a note")
        }
      }
      .padding(.horizontal, 7)
      .frame(height: 45)
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(isSelected ? 0.13 : isHovered ? 0.05 : 0))
      }
    }
    .buttonStyle(.plain)
    .focusable(false)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct ListSidebar: View {
  @Bindable var state: ListModel
  let chrome: ChromeModel
  let app: AppModel
  let onSelect: (String?) -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: 42)
      FilterStrip(state: chrome, app: app, isInSidebar: true) { state.focusRequest += 1 }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(state.sections) { section in
              HStack(spacing: 6) {
                Text(section.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.75))
                Text("\(section.rows.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 8)
              .padding(.top, 12)
              .padding(.bottom, 5)
              ForEach(section.rows) { row in
                ListRow(row: row, isSelected: row.id == state.selection) {
                  onSelect(row.id)
                  isFocused = true
                }
                .id(row.id)
              }
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onChange(of: state.selection) { _, next in
          if let next { reader.scrollTo(next) }
        }
        .onChange(of: state.focusRequest) { isFocused = true }
        .onAppear {
          isFocused = true
          if let selection = state.selection { reader.scrollTo(selection) }
        }
        .overlay {
          if state.sections.isEmpty {
            Text("Nothing here matches.").font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
      }
    }
    .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
  }

  private func move(_ step: Int) -> KeyPress.Result {
    let ids = state.ids
    guard !ids.isEmpty else { return .ignored }
    let current = state.selection.flatMap(ids.firstIndex(of:))
    let next = current.map { min(ids.count - 1, max(0, $0 + step)) } ?? 0
    onSelect(ids[next])
    return .handled
  }
}

/// The list view: every component down the side, one in the person's hands, and its dials beside it.
final class ListController {
  private unowned let model: AppModel
  let state = ListModel()
  private let container = FlippedView()
  private let material = NSVisualEffectView()
  private let shadow = FlippedView()
  private let clip = FlippedView()
  private lazy var sidebar: NSHostingView<ListSidebar>? = model.chrome.map { chrome in
    NSHostingView(rootView: ListSidebar(state: state, chrome: chrome.state, app: model) { [weak self] in self?.select($0) })
  }
  private lazy var controls = NSHostingView(rootView: StageControls(model: model.focus?.inspector.model ?? InspectorModel()))
  private(set) var stage: LiveStage?
  private var shownId: String?
  private var filter = ProjectFilter.all
  private var refinement = Refinement()
  private(set) var isActive = false
  private let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  private static let sidebarWidth = 256.0
  /// How far the floating bar shifts to stay centred over the stage between the sidebar and the dials.
  static let barOffset = (sidebarWidth - Stand.inspectorWidth) / 2

  init(model: AppModel, root: NSView, above canvas: NSView) {
    self.model = model
    container.frame = root.bounds
    container.autoresizingMask = [.width, .height]
    container.isHidden = true
    root.addSubview(container, positioned: .above, relativeTo: canvas)
    material.material = .sidebar
    material.blendingMode = .withinWindow
    material.state = .active
    shadow.wantsLayer = true
    shadow.layer?.shadowColor = NSColor.black.cgColor
    shadow.layer?.shadowOpacity = 0.22
    shadow.layer?.shadowRadius = 28
    shadow.layer?.shadowOffset = CGSize(width: 0, height: 10)
    shadow.layer?.masksToBounds = false
    clip.wantsLayer = true
    clip.layer?.cornerCurve = .continuous
    clip.layer?.masksToBounds = true
    shadow.addSubview(clip)
    controls.safeAreaRegions = []
    for view in [material, shadow, controls] as [NSView] { container.addSubview(view) }
  }

  var selectedId: String? { isActive ? shownId : nil }

  func enter(_ filter: ProjectFilter, refinement: Refinement) {
    isActive = true
    self.filter = filter
    self.refinement = refinement
    if let sidebar, sidebar.superview == nil {
      sidebar.safeAreaRegions = []
      container.addSubview(sidebar, positioned: .above, relativeTo: material)
    }
    container.isHidden = false
    refresh()
    relayout()
    state.focusRequest += 1
  }

  func leave() {
    guard isActive else { return }
    isActive = false
    showStage(for: nil)
    container.isHidden = true
  }

  /// Rebuilds the rows after the board or a status changed. The row in hand stays until the person moves
  /// on, so tuning something out of a status filter doesn't pull it away from under them.
  func refresh(keepingSelected: Bool = true) {
    guard isActive, let store = model.store else { return }
    let statuses = model.statuses
    let held = keepingSelected ? state.selection : nil
    let sections = store.sections(for: filter, componentsOnly: true) { [refinement] item in
      item.id == held || refinement.matches(item, statuses.status(item.id))
    }
    state.sections = sections.map { section in
      ListModel.Section(id: section.title, title: section.title, rows: section.ids.compactMap { id in
        store.items[id].map { ListModel.Row(id: id, title: $0.title, picture: model.plates?.plate(for: id)?.image, ground: $0.ground, status: statuses.status(id)) }
      })
    }
    let ids = state.ids
    let next = ids.contains { $0 == state.selection } ? state.selection : ids.first
    state.selection = next
    if next != shownId { showStage(for: next) }
  }

  func setFilter(_ filter: ProjectFilter) {
    self.filter = filter
    refresh(keepingSelected: false)
  }

  func refine(_ next: Refinement) {
    refinement = next
    refresh(keepingSelected: false)
  }

  func select(_ id: String?) {
    state.selection = id
    if id != shownId { showStage(for: id) }
    refresh()
  }

  /// Walks the rows from anywhere, even with the keyboard inside the component.
  func selectNeighbor(by step: Int) {
    let ids = state.ids
    guard let selection = state.selection, let at = ids.firstIndex(of: selection), ids.indices.contains(at + step) else { return }
    select(ids[at + step])
  }

  func focusRows() {
    state.focusRequest += 1
  }

  private func showStage(for id: String?) {
    model.focus?.releaseBefore()
    if let stage {
      if let shownId, model.focus?.consumeDialsChanged() == true { model.plates?.invalidate(shownId) }
      model.pool.release(stage)
      self.stage = nil
    }
    shownId = id
    guard let id, let item = model.store?.items[id], let stage = model.pool.acquire(id, for: self) else {
      model.focus?.unpin()
      shadow.isHidden = true
      controls.isHidden = true
      return
    }
    self.stage = stage
    stage.web.isInteractive = true
    stage.handOver()
    clip.addSubview(stage.web)
    clip.layer?.backgroundColor = item.ground.cgColor
    shadow.isHidden = false
    controls.isHidden = false
    let isReady = stage.phase == .ready
    stage.web.alphaValue = isReady ? 1 : 0
    if !isReady { stage.onReady = { [weak self, weak stage] in if let stage { self?.reveal(stage) } } }
    model.focus?.pin(item)
    relayout()
  }

  private func reveal(_ stage: LiveStage) {
    stage.onReady = nil
    guard stage === self.stage else { return }
    if calm {
      stage.web.alphaValue = 1
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        stage.web.animator().alphaValue = 1
      }
    }
  }

  func relayout() {
    guard isActive else { return }
    let bounds = container.bounds
    let side = CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height)
    material.frame = side
    sidebar?.frame = side
    guard let id = shownId, let item = model.store?.items[id], case .component(let viewport, let crop) = item.body, let stage else { return }
    // The floating bar stands over the top of this area, so the component starts below it.
    let area = CGRect(x: Self.sidebarWidth, y: 76, width: bounds.width - Self.sidebarWidth - Stand.inspectorWidth, height: bounds.height - 76).insetBy(dx: 32, dy: 0)
    let room = area.height - 68
    let w = max(120, Stand.width(of: item, inWidth: area.width, height: room))
    let h = w * item.aspect
    let rect = CGRect(x: area.midX - w / 2, y: area.minY + max(0, (room - h) / 2), width: w, height: h)
    shadow.frame = rect
    clip.frame = shadow.bounds
    let radius = TileView.radius(forWidth: w)
    clip.layer?.cornerRadius = radius
    shadow.layer?.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    stage.present(viewport: viewport, crop: crop, scale: w / crop.w)
    let size = controls.fittingSize
    controls.frame = CGRect(x: rect.midX - size.width / 2, y: rect.maxY + 14, width: size.width, height: size.height)
  }

  var stageWeb: StageWebView? { stage?.web }

  func debugState() -> JSON {
    ["active": isActive, "selected": shownId ?? NSNull(), "rows": state.sections.flatMap(\.rows).count, "sections": state.sections.map(\.title), "ready": stage?.phase == .ready, "stage": stage != nil, "shadow": ["x": shadow.frame.minX, "y": shadow.frame.minY, "w": shadow.frame.width, "h": shadow.frame.height] as JSON, "controls": ["x": controls.frame.minX, "y": controls.frame.minY, "w": controls.frame.width, "h": controls.frame.height] as JSON, "scale": stage?.web.pageZoom ?? 0, "webY": stage?.web.frame.minY ?? 0, "responder": container.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
  }
}
