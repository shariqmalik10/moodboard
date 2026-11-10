import AppKit
import SwiftUI
import WebKit

/// Everything a person can do from the panel.
enum InspectorAction {
  case close
  case remove
  case updateFromPaper
  case startOver
  case watch
  case holdBefore(Bool)
  case noteEdited(String)
  case revert(DialChange)
  case revertAll
  case copyChanges
  case copyBrief
  case toggleBuilt
  case dismissLost
  case handoff(HandoffAction)
}

/// Sending a component to Claude Code, from the panel.
enum HandoffAction {
  case send
  case stop
  case resume
  case signIn
  case chooseRepository
}

@Observable
final class InspectorModel {
  var itemId: String?
  var title = ""
  var isComponent = false
  var canUpdateFromPaper = false
  /// A component from a connected project, whose dials edit its source instead of a tune kept in the app.
  var isProject = false
  /// The files a project component's dials edit.
  var sourceFile: String?
  /// The list view keeps the dials showing, so there's nothing to close.
  var isPinned = false
  /// What the person wants from this component. It stays with the component until it's built.
  var note = ""
  var changes: [DialChange] = []
  var lostTune: [String] = []
  var paper: PaperState?
  var status = ComponentStatus()
  var builtLine: String?
  var resumableSession: String?
  var isUpdating = false
  var showsBefore = false
  var repository: URL?
  var recentRepositories: [URL] = []
  var run: HandoffRun?
  var onAction: (InspectorAction) -> Void = { _ in }
}

/// The panel beside an open tile: DialKit in the middle, and the note and Send to Claude Code below it.
final class InspectorView: NSView {
  let model = InspectorModel()
  private let webHost: WebHost
  private let material = NSVisualEffectView()
  private let panel: StageWebView
  private let header: NSHostingView<InspectorHeader>
  private let footer: NSHostingView<InspectorFooter>

  override var isFlipped: Bool { true }

  init(webHost: WebHost) {
    self.webHost = webHost
    panel = webHost.makeWebView()
    header = NSHostingView(rootView: InspectorHeader(model: model))
    footer = NSHostingView(rootView: InspectorFooter(model: model))
    super.init(frame: .zero)
    wantsLayer = true
    autoresizingMask = [.height, .minXMargin]
    material.material = .sidebar
    material.blendingMode = .withinWindow
    material.state = .active
    panel.isInteractive = true
    panel.setValue(false, forKey: "drawsBackground")
    for view in [material, panel, header, footer] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      material.topAnchor.constraint(equalTo: topAnchor),
      material.bottomAnchor.constraint(equalTo: bottomAnchor),
      material.leadingAnchor.constraint(equalTo: leadingAnchor),
      material.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      panel.topAnchor.constraint(equalTo: header.bottomAnchor),
      panel.leadingAnchor.constraint(equalTo: leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: trailingAnchor),
      panel.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

  var panelWeb: WKWebView { panel }

  func show(item: Item) {
    model.itemId = item.id
    model.title = item.title
    model.isComponent = item.isComponent
    model.canUpdateFromPaper = ComponentLibrary.contains(item.id)
    model.isProject = ProjectCatalog.contains(item.id)
    model.sourceFile = ProjectCatalog.row(item.id)?.file
    if item.isComponent {
      var components = URLComponents(url: SchemeHandler.root.appending(path: "panel.html"), resolvingAgainstBaseURL: false)
      components?.queryItems = [URLQueryItem(name: "id", value: item.id)]
      if let url = components?.url { panel.load(URLRequest(url: url)) }
      panel.isHidden = false
    } else {
      panel.isHidden = true
    }
  }

  func hide() {
    panel.loadHTMLString("", baseURL: nil)
    model.note = ""
  }

  /// Moves dials in the open panel, for a tune that came from Claude Code.
  func setDials(_ values: JSON) {
    for (path, value) in values {
      panel.callAsyncJavaScript("window.__setDial && window.__setDial(path, value)", arguments: ["path": path, "value": value], in: nil, in: .page, completionHandler: nil)
    }
  }
}

/// Under a component that's in the person's hands: back to how it began, the scripted demo once, and,
/// once anything is tuned, a look at how it was designed for as long as it's held.
struct StageControls: View {
  let model: InspectorModel
  @Environment(\.accessibilityReduceMotion) private var calm

  var body: some View {
    HStack(spacing: 0) {
      Button { model.onAction(.startOver) } label: {
        Label("Start over", systemImage: "arrow.counterclockwise").padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
      }
      .help("Put this component back to how it began")
      Button { model.onAction(.watch) } label: {
        Label("Watch it play", systemImage: "play.fill").padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
      }
      .help("Play the demo once. Moving your pointer over the component ends it.")
      // Comparing a project's component would mean writing to its file and back while the key is held.
      if !model.changes.isEmpty, !model.isProject {
        Divider().frame(height: 16)
        Label(model.showsBefore ? "Showing as designed" : "Hold to compare", systemImage: "circle.lefthalf.filled")
          .padding(.horizontal, 12)
          .frame(height: 32)
          .contentShape(Rectangle())
          .foregroundStyle(model.showsBefore ? Color.accentColor : .primary)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { _ in if !model.showsBefore { model.onAction(.holdBefore(true)) } }
              .onEnded { _ in model.onAction(.holdBefore(false)) }
          )
          .help("Hold this, or hold the Option key, to see the component as it was designed")
          .accessibilityLabel("Compare with the design")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { model.onAction(.holdBefore(!model.showsBefore)) }
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .glassEffect()
    .fixedSize()
  }
}

/// What the person has moved, each with a button that puts it back.
private struct ChangesSection: View {
  let model: InspectorModel
  @State private var isOpen = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button { isOpen.toggle() } label: {
          HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
            Text("\(model.changes.count) \(model.isProject ? "changed" : "tuned")").font(.system(size: 12, weight: .semibold))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Hide what you tuned" : "Show what you tuned")
        Spacer()
        Button("Copy") { model.onAction(.copyChanges) }.buttonStyle(.link).font(.system(size: 12)).help("Copy every change as text")
        Button("Reset all") { model.onAction(.revertAll) }.buttonStyle(.link).font(.system(size: 12)).help(model.isProject ? "Put every dial back to where it was, in the file too" : "Put every dial back to the design")
      }
      if isOpen {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(model.changes) { change in
              HStack(spacing: 6) {
                Text(change.label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                value(change.from).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                value(change.to)
                Button { model.onAction(.revert(change)) } label: {
                  Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Put \(change.label) back to \(change.fromText)")
                .accessibilityLabel("Put \(change.label) back to \(change.fromText)")
              }
              .frame(minHeight: 22)
            }
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(CGFloat(model.changes.count) * 24, 124))
      }
    }
  }

  @ViewBuilder private func value(_ raw: Any) -> some View {
    let text = DialChange.show(raw)
    HStack(spacing: 3) {
      if let color = NSColor(hex: text) {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(Color(nsColor: color))
          .frame(width: 10, height: 10)
          .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
      }
      Text(text).font(.system(size: 11).monospacedDigit()).lineLimit(1).frame(maxWidth: 74, alignment: .trailing)
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct InspectorHeader: View {
  let model: InspectorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        if !model.isComponent {
          Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        Spacer()
        Menu {
          if model.isComponent {
            Button("Copy Brief for Claude Code") { model.onAction(.copyBrief) }
            if !model.isProject {
              Button(model.status.build == .never ? "Mark as Built" : "Mark as Not Built") { model.onAction(.toggleBuilt) }
            }
            Divider()
          }
          if model.canUpdateFromPaper {
            Button("Update from Paper") { model.onAction(.updateFromPaper) }
          }
          Button("Take off the wall") { model.onAction(.remove) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")

        if !model.isPinned {
          Button { model.onAction(.close) } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .help("Close")
          .accessibilityLabel("Close")
        }
      }
      if model.paper == .changed {
        notice("Paper has a newer version of this design.", tint: .orange) {
          Button(model.isUpdating ? "Updating…" : "Update") { model.onAction(.updateFromPaper) }.controlSize(.small).disabled(model.isUpdating)
        }
      } else if model.paper == .missing {
        notice("This frame is no longer in Paper. What you see here is the last version.", tint: .secondary) { EmptyView() }
      }
      if !model.lostTune.isEmpty {
        notice("Paper changed the value behind \(model.lostTune.joined(separator: ", ")), so that tune no longer applies.", tint: .orange) {
          Button("OK") { model.onAction(.dismissLost) }.controlSize(.small)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 10)
    .padding(.bottom, 4)
  }

  private func notice<Action: View>(_ text: String, tint: Color, @ViewBuilder action: () -> Action) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      action()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
  }
}

struct InspectorFooter: View {
  @Bindable var model: InspectorModel

  var body: some View {
    if model.isComponent {
      VStack(alignment: .leading, spacing: 8) {
        Divider().padding(.horizontal, -12)
        // Down here it grows upward, so the dial under the pointer stays where it is as the first change lands.
        if !model.changes.isEmpty {
          ChangesSection(model: model)
          Divider().padding(.horizontal, -12)
        }
        if let run = model.run {
          HandoffStatus(run: run, onResume: { model.onAction(.handoff(.resume)) }, onSignIn: { model.onAction(.handoff(.signIn)) })
        } else if let line = model.builtLine {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if model.resumableSession != nil { Button("Continue in Terminal") { model.onAction(.handoff(.resume)) }.buttonStyle(.link).font(.system(size: 12)) }
          }
        }
        if let file = model.sourceFile {
          Text("Dials edit \(file)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).help(file)
        }
        // Only the person's own typing goes through here. The app filling the field in must not save over a note.
        TextField("Note for Claude Code…", text: Binding(get: { model.note }, set: { model.note = $0; model.onAction(.noteEdited($0)) }), axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...5)
          .font(.system(size: 13))
          .accessibilityLabel("Note for Claude Code")
          .help("Stays with this component. Claude Code reads it with the design.")
        HStack(spacing: 6) {
          Menu {
            ForEach(model.recentRepositories, id: \.self) { url in
              Button(url.lastPathComponent) { model.repository = url }
            }
            if !model.recentRepositories.isEmpty { Divider() }
            Button("Choose a folder…") { model.onAction(.handoff(.chooseRepository)) }
          } label: {
            Label(model.repository?.lastPathComponent ?? "Choose a repository", systemImage: "folder")
              .font(.system(size: 12))
              .lineLimit(1)
          }
          .menuStyle(.borderlessButton)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Repository")
          Spacer()
          if model.run?.isWorking == true {
            Button { model.onAction(.handoff(.stop)) } label: {
              Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Stop Claude Code")
            .accessibilityLabel("Stop Claude Code")
          } else {
            Button { model.onAction(.handoff(.send)) } label: {
              Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.repository == nil || model.run?.isOver == false)
            .help(model.repository == nil ? "Choose a repository first" : "Send to Claude Code, which can edit files in \(model.repository?.lastPathComponent ?? "this folder") (⌘Return)")
            .accessibilityLabel("Send to Claude Code")
          }
        }
      }
      .padding(12)
    }
  }
}

struct HandoffStatus: View {
  let run: HandoffRun
  let onResume: () -> Void
  let onSignIn: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if run.isWorking { ProgressView().controlSize(.mini) }
      Text(run.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
      Spacer(minLength: 0)
      if run.needsSignIn {
        Button("Sign in", action: onSignIn).buttonStyle(.link).font(.system(size: 12))
      } else if run.sessionId != nil, !run.isWorking {
        Button("Continue in Terminal", action: onResume).buttonStyle(.link).font(.system(size: 12))
      }
    }
  }
}

/// One request sent to Claude Code, as the inspector shows it.
@Observable
final class HandoffRun {
  enum Phase {
    case starting
    case running(Process)
    /// Claude Code said how it ended, and its process hasn't exited yet.
    case reported(Outcome, Process)
    case ended(Outcome)
  }

  enum Outcome {
    /// The first line of what Claude Code said when it finished.
    case built(summary: String)
    case failed(needsSignIn: Bool)
  }

  let repository: URL
  private(set) var phase = Phase.starting
  private(set) var status = "Starting Claude Code…"
  private(set) var sessionId: String?
  private(set) var changedFiles: Set<String> = []
  private var lastError: String?

  init(repository: URL) {
    self.repository = repository
  }

  /// Claude Code is still at work, so the inspector offers Stop.
  var isWorking: Bool {
    switch phase {
    case .starting, .running: true
    case .reported, .ended: false
    }
  }

  /// Its last line has arrived, or will never come.
  var hasReported: Bool { !isWorking }

  /// Nothing of this run is left, so another can start.
  var isOver: Bool {
    if case .ended = phase { true } else { false }
  }

  var needsSignIn: Bool {
    switch phase {
    case .reported(.failed(true), _), .ended(.failed(true)): true
    default: false
    }
  }

  var builtSummary: String? {
    if case .ended(.built(let summary)) = phase { summary } else { nil }
  }

  func started(_ process: Process) {
    guard case .starting = phase else { return }
    phase = .running(process)
  }

  func stop() {
    switch phase {
    case .running(let process), .reported(_, let process): process.terminate()
    case .starting, .ended: break
    }
  }

  func apply(_ event: HandoffEvent) {
    switch event {
    case .started(let session):
      sessionId = session
    case .working(let text, let changed):
      status = text
      if let changed { changedFiles.insert(changed) }
    case .finished(let summary, let session):
      sessionId = session ?? sessionId
      finish(summary.isEmpty ? "Done." : summary)
    case .failed(let reason, let session):
      sessionId = session ?? sessionId
      fail(reason.isEmpty ? "Claude Code stopped before finishing." : reason)
    case .nothing:
      break
    }
  }

  private func finish(_ text: String) {
    let count = changedFiles.count
    status = count == 0 ? text : "\(count == 1 ? "1 file" : "\(count) files") changed. \(text)"
    report(.built(summary: text))
  }

  func fail(_ reason: String) {
    let needsSignIn = reason.range(of: "authenticate|log ?in|sign ?in", options: [.regularExpression, .caseInsensitive]) != nil
    status = needsSignIn ? "Claude Code on this Mac needs you to sign in. After that, send again." : reason
    report(.failed(needsSignIn: needsSignIn))
  }

  private func report(_ outcome: Outcome) {
    switch phase {
    case .starting: phase = .ended(outcome)
    case .running(let process): phase = .reported(outcome, process)
    case .reported, .ended: break
    }
  }

  func noteError(_ line: String) {
    lastError = line
  }

  /// The process has gone. If it never said how it ended, this is the only news there is.
  func ended(status code: Int32, stoppedByPerson: Bool) {
    switch phase {
    case .reported(let outcome, _):
      phase = .ended(outcome)
    case .running:
      if stoppedByPerson {
        fail("Stopped.")
      } else if code == 127 {
        fail("Couldn't find Claude Code. Is `claude` installed for this user?")
      } else {
        fail("Claude Code stopped. \(lastError ?? "It exited with code \(code).")")
      }
      if case .reported(let outcome, _) = phase { phase = .ended(outcome) }
    case .starting, .ended:
      break
    }
  }
}
