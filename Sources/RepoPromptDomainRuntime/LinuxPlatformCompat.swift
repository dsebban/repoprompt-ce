#if os(Linux)
import CoreFoundation
import Foundation
import Glibc

/// Linux-only stand-in for the `Darwin.` qualifier used by this target's libc call sites.
/// Each member forwards to the identical glibc call. This is a type, not a module, so
/// `canImport(Darwin)` stays false on Linux.
enum Darwin {
    @discardableResult
    static func close(_ fd: Int32) -> Int32 {
        Glibc.close(fd)
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buffer, count)
    }
}

// swift-corelibs-foundation does not re-export CoreFoundation; forward the CF calls used here.
func CFGetTypeID(_ object: AnyObject) -> CFTypeID {
    CoreFoundation.CFGetTypeID(object)
}

func CFBooleanGetTypeID() -> CFTypeID {
    CoreFoundation.CFBooleanGetTypeID()
}

/// Linux stand-in for `os.OSAllocatedUnfairLock`, limited to the API this target uses.
final class OSAllocatedUnfairLock<State> {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

extension OSAllocatedUnfairLock: @unchecked Sendable where State: Sendable {}
#endif
