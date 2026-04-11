// coder-island-hook: thin bridge between Claude Code hook scripts and
// the running Coder Island app. Shipped inside the .app bundle at
// Contents/Helpers/coder-island-hook and exec'd by the installed shell
// stubs in ~/.coder-island/hooks/.
//
// Wire protocol (line-delimited, Unix domain socket):
//   Request  (helper → app): "<ACTION>\n<JSON payload>"   then shutdown(SHUT_WR)
//   Response (app → helper): "<hook output JSON>"          then close
//
// ACTION is "permission", "ask", or "event" — passed as argv[1].
// Socket path: ~/.coder-island/hook.sock
//
// Failure modes: if the socket is missing, connect fails, or anything
// goes wrong, the helper exits 0 with no output so Claude Code silently
// falls back to its default behavior (same graceful-degradation
// semantics as the pre-migration curl-based scripts).
//
// Why everything is inside `run()`: Swift top-level code stores its
// variables as lazy globals, and we saw intermittent corruption of
// buffer-pointer lifetimes inside `withUnsafeBufferPointer { send(...) }`
// when those buffers were top-level. Moving the whole flow into a
// function makes them plain stack locals and the send loop becomes
// deterministic.

import Foundation
import Darwin

@discardableResult
private func run() -> Int32 {
    // Ignore SIGPIPE so a closed peer returns EPIPE instead of killing us.
    signal(SIGPIPE, SIG_IGN)

    let args = CommandLine.arguments
    guard args.count >= 2, !args[1].isEmpty else { return 0 }
    let action = args[1]

    let payloadData = FileHandle.standardInput.readDataToEndOfFile()
    let payload = [UInt8](payloadData)

    let socketPath = NSString(string: "~/.coder-island/hook.sock").expandingTildeInPath

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return 0 }
    defer { close(fd) }

    // Belt + suspenders: also set the per-socket no-SIGPIPE option.
    var noSig: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < sunPathCapacity else { return 0 }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { cstr in
            for i in 0..<pathBytes.count { cstr[i] = CChar(bitPattern: pathBytes[i]) }
            cstr[pathBytes.count] = 0
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let connectResult = withUnsafePointer(to: &addr) { aPtr -> Int32 in
        aPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return 0 }

    // Build request: "<action>\n<payload>"
    var request: [UInt8] = []
    request.reserveCapacity(action.utf8.count + 1 + payload.count)
    request.append(contentsOf: action.utf8)
    request.append(0x0A)
    request.append(contentsOf: payload)

    // Send in a loop to handle short writes.
    var sent = 0
    while sent < request.count {
        let n = request.withUnsafeBufferPointer { buf -> Int in
            Darwin.send(fd, buf.baseAddress!.advanced(by: sent), request.count - sent, 0)
        }
        if n <= 0 { return 0 }
        sent += n
    }

    // Signal end-of-request so the server reads until EOF.
    _ = shutdown(fd, SHUT_WR)

    // Read response until EOF.
    var response: [UInt8] = []
    let bufSize = 4096
    var buf = [UInt8](repeating: 0, count: bufSize)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { mbuf -> Int in
            Darwin.recv(fd, mbuf.baseAddress, bufSize, 0)
        }
        if n <= 0 { break }
        response.append(contentsOf: buf[0..<n])
    }

    // Write response to stdout via raw write(2).
    var outSent = 0
    while outSent < response.count {
        let n = response.withUnsafeBufferPointer { rbuf -> Int in
            Darwin.write(1, rbuf.baseAddress!.advanced(by: outSent), response.count - outSent)
        }
        if n <= 0 { break }
        outSent += n
    }

    return 0
}

exit(run())
