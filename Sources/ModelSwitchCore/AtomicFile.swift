import Darwin
import Foundation

public enum FileFailure: Error, Equatable, LocalizedError {
    case notFound(String)
    case parentNotWritable(String)
    case writeFailed(String)
    case createDirectoryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "File not found: \(path)"
        case .parentNotWritable(let path): return "Directory is not writable: \(path)"
        case .writeFailed(let message): return message
        case .createDirectoryFailed(let path): return "Could not create directory: \(path)"
        }
    }
}

public enum AtomicFile {
    public static func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileFailure.notFound(url.path)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw FileFailure.writeFailed("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    public static func mode(of url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue
    }

    public static func isDirectoryWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Write `data` through a sibling temp file and rename it over `url`.
    /// The target's current mode is preserved; a new file gets `mode ?? 0o644`.
    public static func write(
        _ data: Data,
        to url: URL,
        mode: Int? = nil
    ) throws {
        let parent = url.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw FileFailure.createDirectoryFailed(parent.path)
            }
        }

        guard isDirectoryWritable(parent) else {
            throw FileFailure.parentNotWritable(parent.path)
        }

        let permissions = mode ?? AtomicFile.mode(of: url) ?? 0o644
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: temporary.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FileFailure.writeFailed("Could not write \(url.path): \(error.localizedDescription)")
        }

        let result = rename(temporary.path, url.path)
        if result != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw FileFailure.writeFailed("Could not replace \(url.path): \(reason)")
        }
    }
}
