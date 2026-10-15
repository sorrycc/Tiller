import Foundation
import Darwin

struct AgentCommand: Codable, Equatable, Sendable {
    var name: String
    var commandLine: String

    static func called(by text: String, in commands: [AgentCommand]) -> AgentCommand? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return commands.first { $0.name == name }
    }

    static func validationMessage(name: String, commandLine: String, others: [AgentCommand]) -> String? {
        guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            return "Use lowercase letters, digits and dashes, starting with a letter or digit."
        }
        guard !others.contains(where: { $0.name == name }) else { return "A command already has that name." }
        guard !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a command line." }
        return nil
    }
}

nonisolated enum AgentCommandRunner {
    struct Result: Sendable {
        let isError: Bool
        let summary: String
    }

    static func run(_ commandLine: String, input: Data, environment: [String: String]) -> Result {
        var stdin: [Int32] = [0, 0]
        guard pipe(&stdin) == 0 else { return Result(isError: true, summary: "Could not open stdin.") }
        var output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else {
            close(stdin[0])
            close(stdin[1])
            return Result(isError: true, summary: "Could not open stdout.")
        }
        guard pipe(&errors) == 0 else {
            close(stdin[0])
            close(stdin[1])
            close(output[0])
            close(output[1])
            return Result(isError: true, summary: "Could not open stderr.")
        }
        defer {
            close(output[0])
            close(errors[0])
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdin[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        for fd in stdin + output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        // Create the group at spawn time, before the shell can start children.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/zsh", "-lc", commandLine].map { $0.withCString { strdup($0) } }
        let variables = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in arguments + variables { free(pointer) } }
        var argv = arguments + [nil], envp = variables + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, &envp)
        close(stdin[0])
        close(output[1])
        close(errors[1])
        guard spawned == 0 else {
            close(stdin[1])
            return Result(isError: true, summary: String(cString: strerror(spawned)))
        }
        _ = fcntl(stdin[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)
        var written = 0
        var inputOpen = true
        defer { if inputOpen { close(stdin[1]) } }
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errors[0], F_SETFL, O_NONBLOCK)
        var stdout = Data(), stderr = Data()
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var timedOut = false
        while true {
            if inputOpen {
                let count = input.withUnsafeBytes { bytes in
                    write(stdin[1], bytes.baseAddress?.advanced(by: written), input.count - written)
                }
                if count > 0 { written += count }
                if written == input.count || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    close(stdin[1])
                    inputOpen = false
                }
            }
            drain(output[0], into: &stdout)
            drain(errors[0], into: &stderr)
            if waitpid(pid, &status, WNOHANG) == pid { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                usleep(500_000)
                kill(-pid, SIGKILL)
                waitpid(pid, &status, 0)
                break
            }
            usleep(10_000)
        }
        drain(output[0], into: &stdout)
        drain(errors[0], into: &stderr)
        let signal = status & 0x7f
        let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        let failed = timedOut || exitStatus != 0
        let data = failed && !stderr.isEmpty ? stderr : stdout
        let preview = String(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).prefix(5).joined(separator: "\n").prefix(500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = timedOut ? "Timed out after 60 seconds (exit status \(exitStatus))." : "Exit status \(exitStatus)."
        return Result(isError: failed, summary: failed ? [preview, outcome].filter { !$0.isEmpty }.joined(separator: "\n") : preview)
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Bound each pass too, so continuous output cannot postpone the timeout.
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            if data.count < 4096 { data.append(contentsOf: buffer.prefix(min(count, 4096 - data.count))) }
        }
    }
}
