// Unix-domain-socket server that replaces the previous HTTP-over-TCP
// HookServer transport. Listens at ~/.coder-island/hook.sock and accepts
// connections from the coder-island-hook helper binary shipped in
// Contents/Helpers/. Each connection carries one request:
//
//   "<ACTION>\n<JSON payload>"    (client shuts down write side = EOF)
//
// and gets back a single response payload (the helper prints it verbatim
// to its stdout, which is captured by Claude Code as the hook output).
//
// Advantages over the previous localhost:19876 HTTP server:
//   * no network stack, no port conflicts, no firewall prompts
//   * chmod 0600 on the socket file gives filesystem-level access control
//   * no HTTP parsing — first newline splits action from payload
//
// Concurrency model: the accept source runs on `queue` (a serial queue
// owned by HookServer). Each accepted connection is read on a concurrent
// background queue so slow/long-running permission requests don't block
// accepts. The user-supplied handler is then invoked back on `queue` so
// state mutations (pendingRequests dict) stay serialized.

import Foundation
import Darwin

final class HookServerSocket {
    typealias Handler = (_ action: String,
                         _ payload: Data,
                         _ reply: @escaping (Data) -> Void) -> Void

    static let defaultPath: String = NSString(string: "~/.coder-island/hook.sock").expandingTildeInPath

    private let path: String
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var handler: Handler?

    init(path: String = HookServerSocket.defaultPath, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    func start(handler: @escaping Handler) throws {
        self.handler = handler

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove any stale socket file from a previous run — bind() fails
        // with EADDRINUSE if the path is still there.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }

        // Non-blocking so accept() can be called in a loop from the
        // DispatchSource event handler without risk of blocking the queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < sunPathCapacity else {
            close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { cstr in
                for i in 0..<bytes.count { cstr[i] = CChar(bitPattern: bytes[i]) }
                cstr[bytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { aPtr -> Int32 in
            aPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.bind(err)
        }

        // Restrict to owner only so no other local user can connect.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw SocketError.listen(err)
        }

        listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFd, fd >= 0 { close(fd) }
            self?.listenFd = -1
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let clientFd = accept(listenFd, nil, nil)
            if clientFd < 0 {
                // Drained — EAGAIN/EWOULDBLOCK is expected on the last iteration.
                return
            }
            // Prevent SIGPIPE on writes to a closed peer — if the helper
            // exited early we want send() to return EPIPE, not crash the
            // whole app.
            var one: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        // Read + dispatch on a concurrent background queue so one slow
        // connection (e.g. a permission request waiting for the user)
        // doesn't starve new accepts.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while true {
                let n = recv(fd, buf, bufSize, 0)
                if n > 0 {
                    data.append(buf, count: n)
                } else {
                    break
                }
            }

            guard let newlineIdx = data.firstIndex(of: 0x0A) else {
                close(fd)
                return
            }
            let actionData = data[data.startIndex..<newlineIdx]
            let payloadStart = data.index(after: newlineIdx)
            let payload = Data(data[payloadStart..<data.endIndex])
            let action = String(data: Data(actionData), encoding: .utf8) ?? ""

            // Reply closure: sends data, shuts down, closes fd.
            // Guarded so it can only fire once (defense against double
            // reply if business logic ever tries).
            var fired = false
            let reply: (Data) -> Void = { body in
                if fired { return }
                fired = true
                var sent = 0
                body.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while sent < body.count {
                        let n = Darwin.send(fd, base.advanced(by: sent), body.count - sent, 0)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                _ = shutdown(fd, SHUT_WR)
                close(fd)
            }

            // Back to server queue for the handler so pendingRequests
            // access stays serialized.
            self?.queue.async {
                self?.handler?(action, payload, reply)
            }
        }
    }

    enum SocketError: Error {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong
    }
}
