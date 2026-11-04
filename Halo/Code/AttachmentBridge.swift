import Foundation

/// One attached file prepared for a sandbox: its name there and its bytes.
struct SandboxFile: Sendable {
    var name: String
    var size: Int
    var data: Data
}

/// Makes a conversation's attachments visible to its sandboxes: Python's Pyodide gets them as real
/// files at /attachments/<name>, the Mac shell's workspace gets links under the same names. Names
/// follow how the user named the files, made unique, and stay stable across the chat.
enum AttachmentBridge {
    /// Pyodide keeps files in memory inside a web view, so bound the payload.
    static let maxFileBytes = 16 << 20
    static let maxTotalBytes = 48 << 20

    /// The chat's attached files in order, each under a unique sandbox name. Skips videos: too big,
    /// and neither sandbox reads them.
    static func entries(in conversation: Conversation) -> [(name: String, item: MediaItem)] {
        var seen = Set<String>()
        var out: [(name: String, item: MediaItem)] = []
        for message in conversation.orderedMessages where message.role == .user {
            for item in message.media {
                guard item.kind != .video else { continue }
                out.append((unique(name: sanitized(item) ?? item.filename, used: &seen), item))
            }
        }
        return out
    }

    /// The chat's attachments as bytes, capped so a sandbox mount can't eat all the memory.
    static func files(in conversation: Conversation) -> [SandboxFile] {
        var out: [SandboxFile] = []
        var total = 0
        for (name, item) in entries(in: conversation) {
            guard let data = MediaStore.data(for: item), data.count <= maxFileBytes else { continue }
            guard total + data.count <= maxTotalBytes else { break }
            total += data.count
            out.append(SandboxFile(name: name, size: data.count, data: data))
        }
        return out
    }

    #if os(macOS)
    /// The workspace a `run_command` shell starts in, with the chat's attachments linked in under
    /// their names so `ls` shows them the way the user named them. Writes stay in the workspace.
    static func workspace(for conversation: Conversation) -> URL {
        let dir = AppFolders.support
            .appendingPathComponent("Shell", isDirectory: true)
            .appendingPathComponent(conversation.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = FileManager.default
        for (name, item) in entries(in: conversation) {
            let link = dir.appendingPathComponent(name)
            let target = MediaStore.url(for: item)
            if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
                if existing == target.path { continue }
                try? manager.removeItem(at: link)   // a link that now points at another chat's file
            } else if manager.fileExists(atPath: link.path) {
                continue   // the model wrote a real file here; never clobber it with a link
            }
            try? manager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        }
        return dir
    }
    #endif

    /// Path separators and other illegal characters out; empty names fall back to the stored file.
    private static func sanitized(_ item: MediaItem) -> String? {
        let raw = item.originalName?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:")).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isNilOrEmpty ? nil : raw
    }

    /// First file keeps its name; later ones become report (2).csv and so on.
    private static func unique(name: String, used: inout Set<String>) -> String {
        guard used.contains(name) else { used.insert(name); return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2...1_000 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !used.contains(candidate) { used.insert(candidate); return candidate }
        }
        return name
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self == nil || self!.isEmpty }
}
