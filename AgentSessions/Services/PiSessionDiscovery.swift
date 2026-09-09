import Foundation

/// Discovery for Pi canonical session JSONL files under ~/.pi/agent/sessions.
final class PiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            guard isPiSessionFile(url) else { continue }
            files.append(url)
        }

        return files
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            }
    }

    private func normalizedSessionsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent("agent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true),
            root.appendingPathComponent("sessions", isDirectory: true),
            root
        ]

        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return root
    }

    /// Maximum records inspected during discovery and the byte ceiling that
    /// backs it. Current builds write one padded title record before the
    /// canonical session header; a short bounded preamble is enough and keeps
    /// discovery from reading whole large files.
    static let maxPreambleRecords = 4
    static let maxPreambleBytes = 32 * 1024

    private func isPiSessionFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        var buffer = Data()
        let newline = Data([0x0A])
        var recordsRead = 0

        while recordsRead < Self.maxPreambleRecords {
            if let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = Data(buffer[range.upperBound..<buffer.endIndex])
                recordsRead += 1
                if lineData.isEmpty { continue }
                if Self.isCanonicalSessionHeader(lineData, decoder: decoder) { return true }
                if !Self.isRecognizedPreambleRecord(lineData, decoder: decoder) { return false }
                continue
            }

            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty {
                recordsRead += 1
                if !buffer.isEmpty, Self.isCanonicalSessionHeader(buffer, decoder: decoder) {
                    return true
                }
                return false
            }
            buffer.append(chunk)
            if buffer.count > Self.maxPreambleBytes { return false }
        }
        return false
    }

    private static func isCanonicalSessionHeader(_ lineData: Data, decoder: JSONDecoder) -> Bool {
        guard let entry = try? decoder.decode(HeaderProbe.self, from: lineData) else { return false }
        guard entry.type == "session" else { return false }
        guard let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return false }
        return true
    }

    private static func isRecognizedPreambleRecord(_ lineData: Data, decoder: JSONDecoder) -> Bool {
        guard let probe = try? decoder.decode(HeaderProbe.self, from: lineData) else { return false }
        return probe.type == "title"
    }

    private struct HeaderProbe: Decodable {
        let type: String
        let id: String?
    }
}
