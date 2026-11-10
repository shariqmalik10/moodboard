import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ChromeModel {
  var message: String?
  var showsPaper = false
  var showsProjects = false
  var mode = ViewMode.wall
  var filter = ProjectFilter.all
  var projects: [String] = []
  var refinement = Refinement()
  var counts: [Attention: Int] = [:]
  var searchFocus = 0
  var density = GridLayout.Density.medium
  /// The bar has too little room for every project by name.
  var isCompact = false
  let paper = PaperPanelModel()
  var onAdd: () -> Void = {}
  var onPaper: () -> Void = {}
}

/// The small floating controls over the wall, and the one line it uses to say something went wrong.
final class ChromeController {
  let state = ChromeModel()
  private unowned let model: AppModel
  private let host: NSHostingView<ChromeView>
  private var clearing: Task<Void, Never>?
  private var center: NSLayoutConstraint?

  init(model: AppModel, root: NSView) {
    self.model = model
    host = NSHostingView(rootView: ChromeView(state: state, model: model))
    host.sizingOptions = [.intrinsicContentSize]
    host.translatesAutoresizingMaskIntoConstraints = false
    // Under the scrim, so an open tile dims it and the inspector covers it.
    root.addSubview(host, positioned: .above, relativeTo: model.canvas)
    let center = host.centerXAnchor.constraint(equalTo: root.centerXAnchor)
    self.center = center
    NSLayoutConstraint.activate([host.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), center])
    state.onAdd = { [weak self] in self?.chooseMaterial() }
    state.onPaper = { [weak self] in self?.state.showsPaper.toggle() }
  }

  /// Keeps the project choices current, and the bar centred over what it sits above.
  func boardChanged() {
    state.projects = model.store?.projects(componentsOnly: state.mode == .list) ?? []
    center?.constant = state.mode == .list ? ListController.barOffset : 0
    state.density = model.canvas?.density ?? .medium
    windowResized()
    guard let store = model.store else { return }
    let shown = store.visibleIds.compactMap { store.items[$0] }.filter { $0.isComponent && state.filter.includes($0) }.map { model.statuses.status($0.id) }
    state.counts = Dictionary(uniqueKeysWithValues: Attention.allCases.map { attention in (attention, shown.filter { $0.matches(attention) }.count) })
    // A status with nothing left in it would leave the view empty with no way to see why.
    if let attention = state.refinement.attention, state.counts[attention] == 0, !model.isTuningInList {
      var next = state.refinement
      next.attention = nil
      model.refine(next)
    }
  }

  func windowResized() {
    state.isCompact = state.mode == .list && (model.root.bounds.width < 1240)
  }

  func importNode(_ node: PaperClient.Node) {
    guard let importer = model.importer, !state.paper.importing.contains(node.id) else { return }
    state.paper.importing.insert(node.id)
    Task {
      defer { state.paper.importing.remove(node.id) }
      do {
        try await importer.importNode(node)
      } catch {
        say(error.localizedDescription)
      }
    }
  }

  var view: NSView { host }

  func say(_ text: String) {
    state.message = text
    clearing?.cancel()
    clearing = Task {
      try? await Task.sleep(for: .seconds(6))
      if !Task.isCancelled { state.message = nil }
    }
  }

  func chooseMaterial() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie]
    panel.allowsMultipleSelection = true
    panel.beginSheetModal(for: model.window) { [weak self] response in
      guard response == .OK, let self else { return }
      let urls = panel.urls
      MainActor.assumeIsolated { self.model.addMaterials(urls, at: nil) }
    }
  }
}

struct ChromeView: View {
  @Bindable var state: ChromeModel
  let model: AppModel
  @Namespace private var marker
  @Environment(\.accessibilityReduceMotion) private var calm
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 8) {
      if let message = state.message {
        Text(message)
          .font(.system(size: 12))
          .padding(.horizontal, 12)
          .frame(height: 32)
          .glassEffect()
          .transition(.opacity)
      }
      VStack(spacing: 8) {
        bar
        if state.mode == .grid { FilterStrip(state: state, app: model, isInSidebar: false) {} }
      }
    }
    .animation(.easeOut(duration: 0.2), value: state.message)
    // Glass keeps its old tint through a live change between light and dark.
    .id(scheme)
  }

  private var bar: some View {
    HStack(spacing: 0) {
      ForEach(ViewMode.allCases) { mode in
        choice(isOn: state.mode == mode, marker: "mode", help: mode.title) {
          model.show(mode)
        } label: {
          Image(systemName: mode.symbol).frame(width: 32, height: 32)
        }
      }
      separator
      if state.isCompact {
        Menu {
          Button("All") { model.show(filter: .all) }
          ForEach(state.projects, id: \.self) { project in
            Button(Projects.name(project)) { model.show(filter: .project(project)) }
          }
        } label: {
          Text(state.filter.title).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .accessibilityLabel("Project")
      } else {
        projectChoice("All", filter: .all)
        ForEach(state.projects, id: \.self) { project in
          projectChoice(Projects.name(project), filter: .project(project))
        }
      }
      separator
      Button(action: state.onAdd) {
        Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
      }
      .help("Add a picture or film")
      .accessibilityLabel("Add a picture or film")
      Button(action: state.onPaper) {
        Image(systemName: "square.and.arrow.down").frame(width: 32, height: 32).contentShape(Rectangle())
      }
      .help("Import from Paper")
      .accessibilityLabel("Import from Paper")
      .popover(isPresented: $state.showsPaper, arrowEdge: .bottom) {
        PaperPanel(state: state.paper) { node in model.chrome?.importNode(node) }
          .onAppear { if let importer = model.importer { state.paper.start(importer) } }
          .onDisappear { state.paper.stop() }
      }
      Button { state.showsProjects.toggle() } label: {
        Image(systemName: "link").frame(width: 32, height: 32).contentShape(Rectangle())
      }
      .help("Connect a Next.js project")
      .accessibilityLabel("Connect a Next.js project")
      .popover(isPresented: $state.showsProjects, arrowEdge: .bottom) {
        ProjectsPanel(
          state: model.projects.state,
          onConnect: {
            state.showsProjects = false
            model.connector.choose()
          },
          onDisconnect: { model.projects.disconnect(slug: $0) },
          onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: $0)]) }
        )
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 13, weight: .medium))
    .padding(.horizontal, 3)
    .glassEffect()
  }

  private var separator: some View {
    Divider().frame(height: 16).padding(.horizontal, 4)
  }

  private func projectChoice(_ title: String, filter: ProjectFilter) -> some View {
    choice(isOn: state.filter == filter, marker: "project", help: "Show \(title == "All" ? "everything" : title)") {
      model.show(filter: filter)
    } label: {
      Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 9).frame(height: 28)
    }
  }

  /// One option of a group, with a marker that slides to whichever is chosen.
  private func choice<Label: View>(isOn: Bool, marker id: String, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
    Button {
      withAnimation(calm ? nil : .spring(response: 0.28, dampingFraction: 1)) { action() }
    } label: {
      label()
        .foregroundStyle(isOn ? .primary : .secondary)
        .contentShape(Rectangle())
        .background {
          if isOn {
            Capsule().fill(.primary.opacity(0.16)).padding(.vertical, 2).matchedGeometryEffect(id: id, in: marker)
          }
        }
    }
    .help(help)
    .accessibilityLabel(help)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// Finds things in Grid and List: a search by name, and the statuses worth asking about right now.
struct FilterStrip: View {
  @Bindable var state: ChromeModel
  let app: AppModel
  let isInSidebar: Bool
  var onLeaveDownward: () -> Void = {}
  @FocusState private var isSearching: Bool

  init(state: ChromeModel, app: AppModel, isInSidebar: Bool, onLeaveDownward: @escaping () -> Void) {
    self.state = state
    self.app = app
    self.isInSidebar = isInSidebar
    self.onLeaveDownward = onLeaveDownward
  }

  var body: some View {
    if isInSidebar {
      VStack(alignment: .leading, spacing: 8) {
        search
        if !chips.isEmpty {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { chipButtons(named: true) }
            HStack(spacing: 2) { chipButtons(named: false); Spacer(minLength: 0) }
          }
        }
        updateAll
      }
    } else {
      HStack(spacing: 6) {
        search.frame(width: 200)
        if !chips.isEmpty {
          Divider().frame(height: 16)
          chipButtons(named: true)
        }
        updateAll
        Divider().frame(height: 16)
        Button { app.canvas?.changeDensity(by: -1); state.density = app.canvas?.density ?? .medium } label: {
          Image(systemName: "minus").frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .disabled(state.density == .small)
        .help("Smaller cards")
        .accessibilityLabel("Smaller cards")
        Button { app.canvas?.changeDensity(by: 1); state.density = app.canvas?.density ?? .medium } label: {
          Image(systemName: "plus").frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .disabled(state.density == .large)
        .help("Larger cards")
        .accessibilityLabel("Larger cards")
      }
      .buttonStyle(.plain)
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 6)
      .frame(height: 34)
      .fixedSize()
      .glassEffect()
    }
  }

  private var search: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
      TextField("Search", text: Binding(get: { state.refinement.query }, set: { next in
        var refined = state.refinement
        refined.query = next
        app.refine(refined)
      }))
      .textFieldStyle(.plain)
      .font(.system(size: 12))
      .focused($isSearching)
      .onSubmit { app.useFirstResult() }
      .onKeyPress(.downArrow) {
        isSearching = false
        onLeaveDownward()
        return .handled
      }
      .onExitCommand {
        clearSearch()
        isSearching = false
      }
      if !state.refinement.query.isEmpty {
        Button(action: clearSearch) {
          Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear the search")
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 26)
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
    .onChange(of: state.searchFocus) { isSearching = true }
  }

  private func clearSearch() {
    var refined = state.refinement
    refined.query = ""
    app.refine(refined)
  }

  /// A status shows only when something has it, or while it's the one chosen.
  private var chips: [Attention] {
    Attention.allCases.filter { (state.counts[$0] ?? 0) > 0 || state.refinement.attention == $0 }
  }

  private func chipButtons(named: Bool) -> some View {
    ForEach(chips) { attention in
      let isOn = state.refinement.attention == attention
      let count = state.counts[attention] ?? 0
      Button {
        var refined = state.refinement
        refined.attention = isOn ? nil : attention
        app.refine(refined)
      } label: {
        HStack(spacing: 4) {
          if named { Text(attention.title).fixedSize() } else { Image(systemName: attention.symbol).font(.system(size: 10, weight: .medium)) }
          Text("\(count)").monospacedDigit().foregroundStyle(isOn ? .primary : .secondary)
        }
        .fixedSize()
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isOn ? .primary : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
        .background(Capsule().fill(.primary.opacity(isOn ? 0.16 : 0)))
      }
      .buttonStyle(.plain)
      .help("Show only: \(attention.title)")
      .accessibilityLabel("\(attention.title), \(count)")
      .accessibilityAddTraits(isOn ? .isSelected : [])
    }
  }

  @ViewBuilder private var updateAll: some View {
    if state.refinement.attention == .paperChanged, (state.counts[.paperChanged] ?? 0) > 0 {
      Button("Update all") { Task { await app.importer?.updateChanged() } }
        .controlSize(.small)
        .help("Bring in every design that changed in Paper. Your tune stays wherever the design still has that value.")
    }
  }
}
