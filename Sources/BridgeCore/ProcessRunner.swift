import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]?, output: (@Sendable (String) -> Void)?) async throws -> ProcessResult
    func start(executable: URL, arguments: [String], environment: [String: String]?, output: (@Sendable (String) -> Void)?) throws -> ManagedProcess
}

/// Runs a specific executable directly, without invoking a shell.
public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String]? = nil, output: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let child = try start(executable: executable, arguments: arguments, environment: environment, output: output)
        return await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.stop()
        }
    }

    public func start(executable: URL, arguments: [String], environment: [String: String]? = nil, output: (@Sendable (String) -> Void)? = nil) throws -> ManagedProcess {
        try ManagedProcess(executable: executable, arguments: arguments, environment: environment, output: output)
    }
}

/// Owns exactly one child process. Stopping it never affects unrelated cloudflared instances.
public final class ManagedProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var result: ProcessResult?
    private var waiters: [CheckedContinuation<ProcessResult, Never>] = []
    private var capturedStdout = Data()
    private var capturedStderr = Data()
    private static let captureLimit = 256 * 1_024

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    fileprivate init(executable: URL, arguments: [String], environment: [String: String]?, output: (@Sendable (String) -> Void)?) throws {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let drainGroup = DispatchGroup()
        for (pipe, isError) in [(stdoutPipe, false), (stderrPipe, true)] {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { drainGroup.leave() }
                while true {
                    // availableData performs one pipe read; fixed-length reads may wait for
                    // their buffer to fill and hide a long-running helper's readiness event.
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    if isError {
                        capturedStderr.append(chunk)
                        if capturedStderr.count > Self.captureLimit { capturedStderr.removeFirst(capturedStderr.count - Self.captureLimit) }
                    } else {
                        capturedStdout.append(chunk)
                        if capturedStdout.count > Self.captureLimit { capturedStdout.removeFirst(capturedStdout.count - Self.captureLimit) }
                    }
                    lock.unlock()
                    output?(String(decoding: chunk, as: UTF8.self))
                }
                try? pipe.fileHandleForReading.close()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit()
            drainGroup.notify(queue: .global(qos: .utility)) { [self] in
                lock.lock()
                let completed = ProcessResult(exitCode: process.terminationStatus, stdout: String(decoding: capturedStdout, as: UTF8.self), stderr: String(decoding: capturedStderr, as: UTF8.self))
                result = completed
                let continuations = waiters
                waiters.removeAll()
                lock.unlock()
                for continuation in continuations { continuation.resume(returning: completed) }
            }
        }
    }

    public func wait() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
            // Process retains its child identity; no name-based kill or stale saved PID.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
