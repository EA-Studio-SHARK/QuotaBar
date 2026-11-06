import Foundation
import Darwin

enum LocalProcess {
    // Bound keychain requests so a permission dialog cannot stall every refresh.
    static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Drain output concurrently, before waiting for the child to exit.
        let reader = DispatchGroup()
        let result = ProcessOutput()
        reader.enter()
        DispatchQueue.global().async {
            result.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw QuotaError.other("读取本机登录信息超时，请确认钥匙串授权后刷新")
        }
        reader.wait()
        guard process.terminationStatus == 0 else {
            throw QuotaError.other("本机登录信息不可用")
        }
        return result.data
    }
}

private final class ProcessOutput: @unchecked Sendable {
    var data = Data()
}
