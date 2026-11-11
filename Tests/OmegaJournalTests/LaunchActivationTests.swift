import Darwin
import Foundation
import Testing
@testable import OmegaJournal

// Regression tests for audit finding MODERN-3 (launch activation).

// MARK: - MODERN-3

/// A background launch (Siri/Shortcuts running "Today's Writing Progress")
/// must not pull the window forward; a raw `.build` binary started from a
/// shell still has to activate itself, because nobody else will.
@Suite("Launch activation")
struct LaunchActivationTests {
    static let rawBinary = URL(fileURLWithPath: "/Users/x/OmegaJournal/.build/out/Products/Debug", isDirectory: true)
    static let appBundle = URL(fileURLWithPath: "/Applications/Omega Journal.app", isDirectory: true)
    static let shellPID: pid_t = 4242

    @Test("raw binary from a shell activates itself")
    func rawBinaryFromShell() {
        #expect(LaunchActivation.shouldForceActivate(bundleURL: Self.rawBinary, parentProcessID: Self.shellPID))
    }

    @Test("bundled app launched by LaunchServices leaves activation to the system")
    func bundledLaunchServices() {
        #expect(!LaunchActivation.shouldForceActivate(bundleURL: Self.appBundle, parentProcessID: 1))
        #expect(!LaunchActivation.shouldForceActivate(
            bundleURL: URL(fileURLWithPath: "/tmp/qa/Omega Journal QA.APP", isDirectory: true), parentProcessID: 1))
    }

    @Test("bundled executable started from a shell or debugger still activates")
    func bundledFromShell() {
        #expect(LaunchActivation.shouldForceActivate(bundleURL: Self.appBundle, parentProcessID: Self.shellPID))
    }

    @Test("a raw binary always activates, whoever launched it")
    func rawBinaryAnyParent() {
        #expect(LaunchActivation.shouldForceActivate(bundleURL: Self.rawBinary, parentProcessID: 1))
    }
}
