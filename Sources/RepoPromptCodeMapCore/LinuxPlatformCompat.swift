#if os(Linux)
import CoreFoundation

// swift-corelibs-foundation does not re-export CoreFoundation; forward the timing API used here.
typealias CFAbsoluteTime = CoreFoundation.CFAbsoluteTime

func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime {
    CoreFoundation.CFAbsoluteTimeGetCurrent()
}
#endif
