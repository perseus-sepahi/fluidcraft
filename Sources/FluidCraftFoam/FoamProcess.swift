import Foundation
import FluidCraftMesh

// MARK: - One-shot runner

/// Run a command to completion and collect its output. For short utilities (mounting,
/// probing) where streaming would be overkill.
/// Output handed from the reader thread to the waiting one.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum FoamProcessRunner {
    struct Result {
        var exitCode: Int32
        var output: String
    }

    static func run(executable: URL, arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil,
                    timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let pipe = Pipe.closeOnExec()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return Result(exitCode: -1, output: "could not launch \(executable.path): \(error.localizedDescription)")
        }
        // Read on a dedicated thread so a chatty child cannot fill the pipe and deadlock us
        // while we wait for it to exit. (Not a GCD queue: when many runs block the shared
        // pool, the read could start after the wait below has given up, losing the output.)
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        let reader = Thread {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 2)
            return Result(exitCode: -2, output: (String(data: box.get(), encoding: .utf8) ?? "") + "\n(timed out)")
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 30)
        return Result(exitCode: p.terminationStatus, output: String(data: box.get(), encoding: .utf8) ?? "")
    }
}

// MARK: - Streaming process

/// A long-running OpenFOAM stage whose output is delivered line by line as it happens and
/// mirrored to a `log.<name>` file in the case, exactly where `Allrun` would put it.
public final class FoamProcess {
    private let process = Process()
    private let pipe = Pipe.closeOnExec()
    private let lock = NSLock()
    private var buffer = Data()
    private var logHandle: FileHandle?
    private let eof = DispatchSemaphore(value: 0)
    private var terminated = false

    public let command: String
    public let arguments: [String]

    /// - Parameters:
    ///   - environment: the activated installation.
    ///   - caseDirectory: the case the command runs in.
    ///   - command/arguments: the OpenFOAM application and its options.
    ///   - logURL: where to mirror output; nil disables the file.
    public init(environment: FoamEnvironment, caseDirectory: URL,
                command: String, arguments: [String], logURL: URL?, requiredApplication: String? = nil) {
        self.command = command
        self.arguments = arguments
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", environment.script(caseDirectory: caseDirectory,
                                                       command: command, arguments: arguments,
                                                       requiredApplication: requiredApplication)]
        process.environment = environment.processEnvironment()
        process.currentDirectoryURL = caseDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Run to completion, calling `onLine` for every complete line of output (from a
    /// background queue). Returns the exit status. Blocking — call from a worker thread.
    public func run(onLine: @escaping (String) -> Void) -> Int32 {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let chunk = fh.availableData
            if chunk.isEmpty {
                // EOF: flush whatever partial line is left, then release the waiter.
                fh.readabilityHandler = nil
                self.flush(final: true, onLine: onLine)
                self.eof.signal()
                return
            }
            self.lock.lock()
            self.buffer.append(chunk)
            self.lock.unlock()
            self.flush(final: false, onLine: onLine)
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            onLine("could not launch \(command): \(error.localizedDescription)")
            try? logHandle?.close()
            return -1
        }
        process.waitUntilExit()
        // The child has exited but the pipe may still hold buffered output; wait for EOF
        // (bounded, in case a grandchild inherited the pipe and lingers).
        _ = eof.wait(timeout: .now() + 5)
        handle.readabilityHandler = nil
        flush(final: true, onLine: onLine)
        try? logHandle?.close()
        return terminated ? -15 : process.terminationStatus
    }

    /// Ask the stage to stop. SIGTERM first — `mpirun` forwards it to every rank and the
    /// OpenFOAM binaries exit cleanly on it — then SIGKILL after a grace period.
    public func terminate() {
        lock.lock(); terminated = true; lock.unlock()
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public var isRunning: Bool { process.isRunning }

    private func flush(final: Bool, onLine: (String) -> Void) {
        lock.lock()
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        if final, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        lock.unlock()
        for line in lines {
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if let h = logHandle { h.write(Data((clean + "\n").utf8)) }
            onLine(clean)
        }
    }
}
