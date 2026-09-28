#if os(Linux)
    import CoreFoundation
    @preconcurrency import Glibc

    /// Linux-only stand-in for the `Darwin.` qualifier used by this target's libc call sites.
    /// Each member forwards to the identical glibc call. This is a type, not a module, so
    /// `canImport(Darwin)` stays false on Linux.
    enum Darwin {
        static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
            Glibc.write(fd, buffer, count)
        }
    }

    /// glibc's `stderr` is a process-constant FILE*; a computed forwarder avoids Swift 6's
    /// global-variable diagnostic without changing the stream used.
    var stderr: UnsafeMutablePointer<FILE>! {
        Glibc.stderr
    }

    /// glibc imports SHUT_* as Int; Darwin call sites expect Int32.
    let SHUT_RDWR = Int32(Glibc.SHUT_RDWR)

    /// swift-corelibs-foundation does not re-export CoreFoundation; forward the CF calls used here.
    func CFGetTypeID(_ object: AnyObject) -> CFTypeID {
        CoreFoundation.CFGetTypeID(object)
    }

    func CFBooleanGetTypeID() -> CFTypeID {
        CoreFoundation.CFBooleanGetTypeID()
    }
#endif
