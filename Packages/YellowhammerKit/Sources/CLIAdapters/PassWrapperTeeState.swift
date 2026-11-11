import Foundation

/// Shared state of the capture reader and the stdout forwarder.
final class PassWrapperTeeState: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [[UInt8]] = []
    private var childExited = false
    private var readerFinished = false
    let readerDone = DispatchSemaphore(value: 0)
    let forwarderDone = DispatchSemaphore(value: 0)

    var hasChildExited: Bool {
        condition.lock()
        defer { condition.unlock() }
        return childExited
    }

    func markChildExited() {
        condition.lock()
        childExited = true
        condition.unlock()
    }

    func enqueue(_ chunk: [UInt8]) {
        condition.lock()
        chunks.append(chunk)
        condition.signal()
        condition.unlock()
    }

    func markReaderFinished() {
        condition.lock()
        readerFinished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks for the next chunk; nil once the reader finished and the queue is empty.
    func nextChunk() -> [UInt8]? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !readerFinished {
            condition.wait()
        }
        return chunks.isEmpty ? nil : chunks.removeFirst()
    }
}
