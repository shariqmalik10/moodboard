import SwiftUI

/// The connect popover: what's connected, how it's going, and why some of a project isn't on the wall.
struct ProjectsPanel: View {
  let state: ProjectsModel
  let onConnect: () -> Void
  let onDisconnect: (String) -> Void
  let onReveal: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if state.lines.isEmpty {
        Text("Connect a Next.js project and its components join the wall. Saved edits show up here at once, and moving a dial edits the file.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(14)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(state.lines) { row($0) }
          }
          .padding(12)
        }
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      Button(action: onConnect) {
        Label("Connect a project…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 36).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .font(.system(size: 13, weight: .medium))
    }
    .frame(width: 340)
  }

  private func row(_ line: ProjectLine) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(line.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Menu {
          Button("Show in Finder") { onReveal(line.root) }
          Button("Disconnect") { onDisconnect(line.slug) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More for \(line.name)")
      }
      if let problem = line.problem {
        Text(problem).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 6) {
          if line.progress != nil { ProgressView().controlSize(.mini) }
          Text(line.progress ?? (line.shown == 1 ? "1 on the wall" : "\(line.shown) on the wall")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      if !line.skipped.isEmpty {
        DisclosureGroup("\(line.skipped.count) can't stand alone") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(line.skipped) { each in
              VStack(alignment: .leading, spacing: 1) {
                Text(each.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(each.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help("\(each.file): \(each.reason)")
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
        .font(.system(size: 12))
      }
    }
  }
}
