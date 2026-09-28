import Foundation
import UniformTypeIdentifiers

/// The hand-off folder between the share extension and the app, in the shared App Group container.
/// This file is compiled into both targets.
///
/// The extension copies each share into its own folder, then opens HydroTone with `openURL`. The app opens
/// the newest complete share the next time HydroTone is on screen, so a share still opens if iOS refused the
/// URL. A newer share replaces an older one that was never opened.
enum SharedInbox {
    static let appGroup = "group.com.hydrotone.app"
    /// The app registers the `hydrotone` scheme. Opening it only brings HydroTone to the screen.
    static let openURL = URL(string: "hydrotone://share")!
    private static let partialSuffix = ".partial"

    struct Item: Sendable {
        let url: URL
        let originalName: String
    }

    static func root() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container.appendingPathComponent("Inbox", isDirectory: true)
    }

    // MARK: Extension side

    /// A new folder for one share. The app ignores it until `finish` renames it.
    /// Names start with the time in milliseconds, so they sort by age.
    static func beginShare(at root: URL, now: Date = .now) throws -> URL {
        let name = String(format: "%013lld-", Int64(now.timeIntervalSince1970 * 1000)) + UUID().uuidString
        let folder = root.appendingPathComponent(name + partialSuffix, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The index prefix keeps the order the items were shared in.
    static func fileName(index: Int, original: String) -> String { String(format: "%02ld_", index) + original }

    /// A file name for a shared item: its suggested name, or its file's name, with a real extension.
    static func originalName(suggested: String?, file: URL?, type: UTType) -> String {
        let fileExtension = file.map(\.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? type.preferredFilenameExtension ?? "dat"
        var base = suggested ?? file?.deletingPathExtension().lastPathComponent ?? ""
        if (base as NSString).pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame {
            base = (base as NSString).deletingPathExtension
        }
        base = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return (base.isEmpty ? "Shared" : base) + "." + fileExtension
    }

    @discardableResult
    static func finish(_ folder: URL) throws -> URL {
        let complete = folder.deletingLastPathComponent()
            .appendingPathComponent(String(folder.lastPathComponent.dropLast(partialSuffix.count)), isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: complete)
        return complete
    }

    // MARK: App side

    /// The files of the newest complete share, in shared order. Older complete shares are deleted.
    /// A partial share older than an hour was abandoned and is deleted too.
    /// The caller moves the files out, then calls `remove` on the folder.
    static func takeNewest(at root: URL, now: Date = .now) -> (folder: URL, items: [Item])? {
        let manager = FileManager.default
        let folders = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var complete: [URL] = []
        for folder in folders {
            guard folder.lastPathComponent.hasSuffix(partialSuffix) else { complete.append(folder); continue }
            if let milliseconds = Double(folder.lastPathComponent.prefix(13)),
               now.timeIntervalSince1970 - milliseconds / 1000 > 60 * 60 { remove(folder) }
        }
        guard let newest = complete.popLast() else { return nil }
        complete.forEach(remove)
        let files = ((try? manager.contentsOfDirectory(at: newest, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { remove(newest); return nil }
        return (newest, files.map { Item(url: $0, originalName: String($0.lastPathComponent.dropFirst(3))) })
    }

    static func remove(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }
}
