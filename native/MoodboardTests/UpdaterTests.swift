import Foundation
import Testing

@testable import Moodboard

struct UpdaterTests {
  private func version(_ text: String) -> Updater.Version { Updater.Version(text)! }

  @Test func `versions compare by number, not by text`() {
    #expect(version("0.1.0") < version("0.1.1"))
    #expect(version("0.9.0") < version("0.10.0"))
    #expect(version("v1.0") == version("1.0.0"))
    #expect(!(version("0.2.0") < version("0.1.9")))
  }

  @Test func `a tag that isn't a version is refused`() {
    #expect(Updater.Version("nightly") == nil)
    #expect(Updater.Version("v1.2-beta") == nil)
    #expect(Updater.Version("") == nil)
  }

  @Test func `a release names its version and its zip`() throws {
    let json = Data("""
      {"tag_name": "v0.2.0", "html_url": "https://github.com/shariqmalik10/moodboard/releases/tag/v0.2.0",
       "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                  {"name": "Moodboard.zip", "browser_download_url": "https://example.com/Moodboard.zip"}]}
      """.utf8)
    let release = try #require(Updater.Release(json: json))
    #expect(release.version == version("0.2.0"))
    #expect(release.zip == URL(string: "https://example.com/Moodboard.zip"))
    #expect(release.notes.isEmpty)
  }

  @Test func `release notes read as headings, bullets and paragraphs`() {
    let notes = "## What's new\r\n\r\n- Moodboard updates itself\r\n* A **Help** item shows these notes\r\n\r\nThanks for trying it."
    #expect(WhatsNewController.blocks(notes) == [
      .heading("What's new"),
      .bullet("Moodboard updates itself"),
      .bullet("A **Help** item shows these notes"),
      .paragraph("Thanks for trying it."),
    ])
  }

  @Test func `a release without the app has nothing to install`() {
    let json = Data(#"{"tag_name": "v0.2.0", "html_url": "https://example.com", "assets": []}"#.utf8)
    #expect(Updater.Release(json: json) == nil)
  }
}
