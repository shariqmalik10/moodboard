import AppKit
import SwiftUI

@Observable
final class PaperPanelModel {
  var isOpen = false
  var failure: String?
  var selection: [PaperClient.Node] = []
  var artboards: [PaperClient.Node] = []
  var fileName = ""
  var pageName = ""
  var thumbnails: [String: NSImage] = [:]
  var importing: Set<String> = []
  private var polling: Task<Void, Never>?

  func start(_ importer: Importer) {
    polling?.cancel()
    polling = Task {
      while !Task.isCancelled {
        await refresh(importer)
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func stop() {
    polling?.cancel()
  }

  private func refresh(_ importer: Importer) async {
    do {
      let (file, page, nodes) = try await importer.paper.artboards()
      fileName = file
      pageName = page
      artboards = nodes
      selection = try await importer.paper.selection()
      failure = nil
      for node in selection + nodes where thumbnails[node.id] == nil {
        if Task.isCancelled { return }
        if let image = await importer.paper.thumbnail(node) { thumbnails[node.id] = image }
      }
    } catch {
      failure = error.localizedDescription
      selection = []
      artboards = []
    }
  }
}

struct PaperPanel: View {
  let state: PaperPanelModel
  let onImport: (PaperClient.Node) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let failure = state.failure {
        VStack(alignment: .leading, spacing: 4) {
          Text(failure).font(.system(size: 13, weight: .medium))
          Text("Open a file in Paper, and its frames appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(14)
      } else if state.fileName.isEmpty {
        ProgressView().controlSize(.small).padding(20).frame(maxWidth: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            if !state.selection.isEmpty {
              heading("Selected")
              ForEach(state.selection) { row($0) }
              Divider().padding(.vertical, 6)
            }
            heading(state.pageName)
            ForEach(state.artboards) { row($0) }
          }
          .padding(8)
        }
        .frame(height: listHeight)
      }
    }
    .frame(width: 320)
  }

  /// A scroll view in a popover has almost no height of its own, so this one is told what its rows need.
  private var listHeight: CGFloat {
    let headings = state.selection.isEmpty ? 1 : 2
    let divider: CGFloat = state.selection.isEmpty ? 0 : 13
    let rows = state.selection.count + state.artboards.count
    return min(460, CGFloat(rows) * 54 + CGFloat(headings) * 24 + divider + 16)
  }

  private func heading(_ text: String) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 4)
  }

  private func row(_ node: PaperClient.Node) -> some View {
    Button {
      onImport(node)
    } label: {
      HStack(spacing: 10) {
        Group {
          if let image = state.thumbnails[node.id] {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
          } else {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
          }
        }
        .frame(width: 40, height: 40)
        VStack(alignment: .leading, spacing: 1) {
          Text(node.name).font(.system(size: 13)).lineLimit(1)
          Text("\(Int(node.width)) × \(Int(node.height))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer(minLength: 0)
        if state.importing.contains(node.id) { ProgressView().controlSize(.small) }
      }
      .padding(6)
      .contentShape(Rectangle())
    }
    .buttonStyle(PaperRowStyle())
    .disabled(state.importing.contains(node.id))
    .accessibilityLabel("Import \(node.name)")
  }
}

private struct PaperRowStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? AnyShapeStyle(.tertiary) : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
      .onHover { isHovered = $0 }
  }
}
