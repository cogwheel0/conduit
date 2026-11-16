// Tests for ShareInbox.swift, as a plain executable (no XCTest, so the
// Command Line Tools are enough): share/test.sh compiles it with the
// inbox and runs it with the manifest golden's path. Exit status 0 means
// every check passed.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) {
  checks += 1
  var passed = false
  do { passed = try condition() } catch { print("error: \(error)") }
  if !passed {
    failures += 1
    print("FAIL line \(line): \(label)")
  }
}

@main
enum InboxTests {
  static func main() throws {
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent(
      "conduit-share-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    let root = scratch.appendingPathComponent("inbox", isDirectory: true)
    let sources = scratch.appendingPathComponent("sources", isDirectory: true)
    try! fm.createDirectory(at: sources, withIntermediateDirectories: true)

    func source(_ name: String, bytes: Int = 4, sparse: Int64? = nil) -> URL {
      let url = sources.appendingPathComponent(name)
      if let sparse {
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.truncate(atOffset: UInt64(sparse))
        try! handle.close()
      } else {
        try! Data(repeating: 0x61, count: bytes).write(to: url)
      }
      return url
    }

    func manifestJSON(_ dir: URL) -> [String: Any]? {
      guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else {
        return nil
      }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // The inbox lives where Conduit looks for it.
    do {
      let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
      check(
        ShareInbox.root(appBundleID: "app.example.conduit", home: home).path
          == "/Users/someone/Library/Caches/app.example.conduit.share-inbox",
        "inbox path")
      check(ShareInbox.link(id: "abc")?.absoluteString == "conduit://share/abc", "link")
      check(ShareInbox.realHome().path.hasPrefix("/"), "a real home")
    }

    // A share is written under <id>.part and published under <id>.
    do {
      let draft = try ShareInbox.begin(root: root)
      check(draft.dir.lastPathComponent == "\(draft.id).part", "part folder")
      check(UUID(uuidString: draft.id) != nil && draft.id == draft.id.lowercased(), "lowercase uuid")
      check(draft.addText("  Tomatoes like six hours of sun.\n") == .added, "text added")
      check(draft.addText("Tomatoes like six hours of sun.") == .duplicate, "text once")
      check(draft.addText(" \n ") == .empty, "blank text")
      check(draft.addURL(URL(string: "https://example.org/allotment/beds")!) == .added, "url")
      check(draft.addURL(URL(string: "https://example.org/allotment/beds")!) == .duplicate, "url once")
      check(try draft.addFile(copying: source("garden plan.pdf")) == .added, "file")
      check(try draft.addData(Data([1, 2, 3]), name: "Image.png") == .added, "data")
      check(try draft.addFile(copying: source("orchard tour.mov", sparse: ShareLimits.maxFileBytes + 1))
        == .tooLarge, "too large")
      check(try draft.addFile(copying: sources) == .notAFile, "a folder is not a file")
      let id = try draft.publish(message: "  What should go in the north bed?  ")
      check(id == draft.id, "published id")
      let final = root.appendingPathComponent(id)
      check(draft.dir == final, "moved to its final name")
      check(!fm.fileExists(atPath: root.appendingPathComponent("\(id).part").path), "no part left")
      check(fm.contentsEqual(
        atPath: final.appendingPathComponent("files/0/garden plan.pdf").path,
        andPath: sources.appendingPathComponent("garden plan.pdf").path), "file copied")
      check(fm.fileExists(atPath: final.appendingPathComponent("files/1/Image.png").path), "data written")
      // The manifest is the one Conduit's tests read (tests/manifest-v1.json).
      let golden = URL(fileURLWithPath: CommandLine.arguments[1])
      let want = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? NSDictionary
      let got = manifestJSON(final).map { $0 as NSDictionary }
      check(want != nil && got == want, "manifest matches tests/manifest-v1.json")
      if got != want { print("got: \(String(describing: got))") }
      do {
        _ = try draft.publish(message: nil)
        check(false, "publishes once")
      } catch {
        check(true, "publishes once")
      }
      draft.withdraw()
      check(!fm.fileExists(atPath: final.path), "withdrawn")
    }

    // At most ten files; names may repeat; a blank message is no message.
    do {
      let draft = try ShareInbox.begin(root: root)
      for _ in 0..<12 {
        _ = try draft.addFile(copying: source("note.txt"))
      }
      check(draft.manifest.files.count == ShareLimits.maxFiles, "ten files")
      check(draft.manifest.tooMany == 2, "two over the limit")
      check(draft.manifest.files[1].path == "files/1/note.txt", "one folder per file")
      _ = try draft.publish(message: "   ")
      check(manifestJSON(draft.dir)?["message"] == nil, "no message")
      draft.withdraw()
    }

    // Cancel removes the unpublished share.
    do {
      let draft = try ShareInbox.begin(root: root)
      _ = draft.addText("Draft text")
      draft.discard()
      check(!fm.fileExists(atPath: draft.dir.path), "discarded")
      check(draft.manifest.isEmpty == false, "a draft with text is not empty")
      check(ShareManifest().isEmpty, "a new manifest is empty")
    }

    // Nothing goes into a share once it is published or cancelled.
    do {
      let draft = try ShareInbox.begin(root: root)
      _ = try draft.publish(message: "Seed swap on Saturday")
      check(draft.addText("Late text") == .closed, "no text after publish")
      check(try draft.addData(Data([1]), name: "late.png") == .closed, "no file after publish")
      check(draft.manifest.files.isEmpty && draft.manifest.texts.isEmpty, "manifest as published")
      draft.withdraw()
      let cancelled = try ShareInbox.begin(root: root)
      cancelled.discard()
      check(cancelled.addURL(URL(string: "https://example.org/late")!) == .closed, "no link after cancel")
      check(try cancelled.addFile(copying: source("late.txt")) == .closed, "no file after cancel")
      check(!fm.fileExists(atPath: cancelled.dir.path), "nothing written after cancel")
    }

    // A provider's answer counts only while the share waits for it.
    do {
      let inTime = ShareWait<String>()
      check(inTime.deliver("garden plan.pdf"), "an answer in time is taken")
      check(inTime.wait(until: .now()) == "garden plan.pdf", "and handed over")
      check(!inTime.deliver("second answer"), "one answer only")
      let late = ShareWait<String>()
      check(late.wait(until: .now()) == nil, "the wait ends at its deadline")
      check(!late.deliver("orchard tour.mov"), "a late answer is refused")
    }

    // Text is cut to the limit.
    do {
      let draft = try ShareInbox.begin(root: root)
      _ = draft.addText(String(repeating: "é", count: ShareLimits.maxTextCharacters + 10))
      check(draft.manifest.texts.first?.count == ShareLimits.maxTextCharacters, "text cut")
      draft.discard()
    }

    // File names stay one path component.
    do {
      check(ShareDraft.safeName("a/b:c.txt") == "a-b-c.txt", "slashes and colons")
      check(ShareDraft.safeName("..hidden") == "hidden", "no leading dots")
      check(ShareDraft.safeName("  ") == "File", "a blank name")
      check(ShareDraft.safeName("tab\there.md") == "tab-here.md", "control characters")
      let long = ShareDraft.safeName(String(repeating: "x", count: 300) + ".jpeg")
      check(long.count == 200 && long.hasSuffix(".jpeg"), "long names keep their extension")
    }

    try? fm.removeItem(at: scratch)
    print("InboxTests: \(checks - failures)/\(checks) passed")
    exit(failures == 0 ? 0 : 1)
  }
}
