import Foundation
import Darwin

/// Receives jobs from the CUPS queue (socket://127.0.0.1:9100 backend): reads
/// everything until the client closes its write side, prints, then closes.
final class JobServer {
    let port: UInt16
    let baseOptions: Options
    private var counter = 0

    init(port: UInt16, options: Options) {
        self.port = port
        self.baseOptions = options
    }

    func start() {
        Thread.detachNewThread { self.run() }
    }

    private func run() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            fail("Port \(port) is already in use: is MunbynBT already running?")
        }
        say("Listening on 127.0.0.1:\(port)")

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            counter += 1
            let number = counter
            say("Job \(number): received \(data.count) bytes")
            if !data.isEmpty {
                jobQueue.sync { self.handle(data, number: number) }
            }
            close(client)
        }
    }

    private func handle(_ data: Data, number: Int) {
        // Preferences are read for every job, so changes made in the menu apply right away.
        var opts = Options.fromSettings()
        opts.names = baseOptions.names
        opts.dryRunDir = baseOptions.dryRunDir
        guard let dir = opts.dryRunDir else {
            runJobReporting(data: data, opts: opts, title: "job \(number)")
            return
        }
        do {
            let base = "\(dir)/job-\(number)"
            try data.write(to: URL(fileURLWithPath: "\(base).bin"))
            let bitmaps = try renderDocument(data, opts: opts)
            try writePreviews(bitmaps, to: "\(base).png")
            var all = Data()
            for j in tsplJobs(bitmaps, opts: opts) { all.append(j) }
            try all.write(to: URL(fileURLWithPath: "\(base).tspl"))
            say("Job \(number): \(bitmaps.count) page(s) saved in \(dir)")
        } catch {
            say("Job \(number): \(error)")
        }
    }
}
