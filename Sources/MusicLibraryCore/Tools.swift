// iOS apps can't launch processes, so ffmpeg, ffprobe and fpcalc are macOS only.
#if os(macOS)
import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
}

public enum ToolError: Error, LocalizedError {
    case notFound(String)
    case failed(tool: String, status: Int32, stderr: String)
    case launchFailed(tool: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "\(name) was not found. Install it with Homebrew (brew install ffmpeg / brew install chromaprint)."
        case .failed(let tool, let status, let stderr):
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "\(tool) exited with status \(status): \(tail)"
        case .launchFailed(let tool, let underlying):
            return "Could not launch \(tool): \(underlying)"
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if running { process.terminate() }
    }

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Returns false if cancellation arrived before launch.
    func launch() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        try process.run()
        running = true
        return true
    }
}

public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], checkStatus: Bool = true) async throws -> ProcessResult {
        let box = ProcessBox()
        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = box.process
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    do {
                        guard try box.launch() else {
                            cont.resume(throwing: CancellationError())
                            return
                        }
                    } catch {
                        cont.resume(throwing: ToolError.launchFailed(tool: executable.lastPathComponent, underlying: error.localizedDescription))
                        return
                    }
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    cont.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: out,
                        stderr: String(decoding: errBox.value, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
        if box.wasCancelled { throw CancellationError() }
        if checkStatus && result.status != 0 {
            throw ToolError.failed(tool: executable.lastPathComponent, status: result.status, stderr: result.stderr)
        }
        return result
    }
}

public struct ToolLocator: Sendable {
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    public let searchPaths: [String]

    public init(searchPaths: [String]? = nil) {
        if let searchPaths {
            self.searchPaths = searchPaths
        } else {
            let envPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
            self.searchPaths = Self.defaultSearchPaths + envPath
        }
    }

    public func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public var ffmpeg: URL? { find("ffmpeg") }
    public var ffprobe: URL? { find("ffprobe") }
    public var fpcalc: URL? { find("fpcalc") }

    public func require(_ name: String) throws -> URL {
        guard let url = find(name) else { throw ToolError.notFound(name) }
        return url
    }
}
#endif
