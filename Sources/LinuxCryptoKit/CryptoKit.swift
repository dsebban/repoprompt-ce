// Linux-only stand-in for Apple's CryptoKit so shared sources keep `import CryptoKit`.
// swift-crypto's `Crypto` module provides the same API surface used here (SHA256).
@_exported import Crypto
