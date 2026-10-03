#if os(Linux)
    import CoreFoundation
    import Dispatch
    import Glibc

    /// Linux-only stand-in for the `Darwin.` qualifier used by this target's libc call sites.
    /// Each member forwards to the identical glibc call. This is a type, not a module, so
    /// `canImport(Darwin)` stays false on Linux.
    enum Darwin {
        static var stderr: UnsafeMutablePointer<FILE>! {
            Glibc.stderr
        }

        static var stdout: UnsafeMutablePointer<FILE>! {
            Glibc.stdout
        }

        static func socket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 {
            Glibc.socket(domain, type, `protocol`)
        }

        static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
            Glibc.bind(fd, address, length)
        }

        static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
            Glibc.listen(fd, backlog)
        }

        static func accept(
            _ fd: Int32,
            _ address: UnsafeMutablePointer<sockaddr>?,
            _ length: UnsafeMutablePointer<socklen_t>?
        ) -> Int32 {
            Glibc.accept(fd, address, length)
        }

        static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
            Glibc.connect(fd, address, length)
        }

        static func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 {
            Glibc.poll(fds, count, timeout)
        }

        static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
            Glibc.read(fd, buffer, count)
        }

        static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
            Glibc.write(fd, buffer, count)
        }

        @discardableResult
        static func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
            Glibc.shutdown(fd, how)
        }

        @discardableResult
        static func close(_ fd: Int32) -> Int32 {
            Glibc.close(fd)
        }
    }

    // glibc imports these as enums/Int; Darwin call sites expect Int32.
    let SOCK_STREAM = Int32(Glibc.SOCK_STREAM.rawValue)
    let SHUT_WR = Int32(Glibc.SHUT_WR)
    let SHUT_RDWR = Int32(Glibc.SHUT_RDWR)

    /// The app-backed proxy's kill-signal watcher uses vnode sources, which exist only on Darwin; its
    /// setup is compiled out on Linux, so the optional source property only needs the protocol type.
    typealias DispatchSourceFileSystemObject = DispatchSourceProtocol

    // Darwin's KERN_PROCARGS2 sysctl has no glibc equivalent. Failing with ENOSYS sends the display-only
    // client-name probe down its existing failure path (callers fall back to the MCP handshake name).
    let CTL_KERN: Int32 = 1
    let KERN_PROCARGS2: Int32 = 49

    func sysctl(
        _: UnsafeMutablePointer<Int32>?,
        _: UInt32,
        _: UnsafeMutableRawPointer?,
        _: UnsafeMutablePointer<Int>?,
        _: UnsafeMutableRawPointer?,
        _: Int
    ) -> Int32 {
        errno = ENOSYS
        return -1
    }

    /// swift-corelibs-foundation does not re-export CoreFoundation; forward the CF calls used here.
    func CFGetTypeID(_ object: AnyObject) -> CFTypeID {
        CoreFoundation.CFGetTypeID(object)
    }

    func CFBooleanGetTypeID() -> CFTypeID {
        CoreFoundation.CFBooleanGetTypeID()
    }
#endif
