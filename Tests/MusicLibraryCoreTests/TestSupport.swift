import Foundation
@testable import MusicLibraryCore

enum TestSupport {
    static let tools = ToolLocator()

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mltest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    @discardableResult
    static func ffmpeg(_ args: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(try tools.require("ffmpeg"), ["-nostdin", "-v", "error", "-y"] + args)
    }

    static func makeAudio(in dir: URL, name: String, ext: String, tags: [String: String] = [:], seconds: Double = 1, frequency: Int = 440) async throws -> URL {
        let url = dir.appendingPathComponent("\(name).\(ext)")
        var args = ["-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(seconds)"]
        for (k, v) in tags { args += ["-metadata", "\(k)=\(v)"] }
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args.append(url.path)
        try await ffmpeg(args)
        return url
    }

    static func makeJPEG(in dir: URL, name: String = "cover", color: String = "red") async throws -> Data {
        let url = dir.appendingPathComponent("\(name).jpg")
        try await ffmpeg(["-f", "lavfi", "-i", "color=c=\(color):s=64x64", "-frames:v", "1", url.path])
        return try Data(contentsOf: url)
    }

    static func makeLibrary() throws -> (root: URL, db: Database, service: ImportService) {
        let root = try tempDir().appendingPathComponent("lib")
        let db = try LibraryLocation.openDatabase(root: root)
        return (root, db, ImportService(root: root, database: db))
    }
}
