import Testing
import Foundation
@testable import Hunch

/// State-machine tests for `DocumentSaveSession`. Each test wires a session
/// with controllable `performSave` / `performFlush` closures, drives it via
/// the public API, and asserts state transitions + side-effect counts.
@Suite("DocumentSaveSession")
@MainActor
struct DocumentSaveSessionTests {

    /// Spy that records calls and lets the test gate `performSave`'s
    /// completion (so we can observe `.saving` intermediate state).
    @MainActor
    final class SaveSpy {
        private(set) var saveStarts = 0
        private(set) var saveCompletes = 0
        private(set) var flushCalls = 0
        var returnValue: Bool = true
        /// When non-nil, `performSave` awaits this continuation before
        /// returning. Tests resume it explicitly via `releasePending()`.
        private var gateContinuation: CheckedContinuation<Void, Never>?
        private(set) var isGated = false

        func gateNext() { isGated = true }

        func releasePending() {
            gateContinuation?.resume()
            gateContinuation = nil
            isGated = false
        }

        func performSave() async -> Bool {
            saveStarts += 1
            if isGated {
                await withCheckedContinuation { cont in
                    gateContinuation = cont
                }
            }
            saveCompletes += 1
            return returnValue
        }

        func performFlush() async {
            flushCalls += 1
        }
    }

    private func makeSession(_ spy: SaveSpy) -> DocumentSaveSession {
        DocumentSaveSession(
            performSave: { await spy.performSave() },
            performFlush: { await spy.performFlush() }
        )
    }

    @Test func startsClean() {
        let session = makeSession(SaveSpy())
        #expect(session.state == .clean)
        #expect(!session.isDirty)
        #expect(!session.isSaving)
    }

    @Test func markDirtyTransitionsToDirty() {
        let session = makeSession(SaveSpy())
        session.markDirty()
        #expect(session.state == .dirty)
        #expect(session.isDirty)
    }

    @Test func saveNowFromCleanIsNoOpUnlessForce() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        let ok = await session.saveNow()
        #expect(ok)
        #expect(spy.saveStarts == 0)
        #expect(session.state == .clean)
    }

    @Test func saveNowForceFromCleanCallsPerformSave() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        _ = await session.saveNow(force: true)
        #expect(spy.saveStarts == 1)
        #expect(spy.saveCompletes == 1)
        #expect(session.state == .clean)
    }

    @Test func saveNowFromDirtyTransitionsToCleanOnSuccess() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        session.markDirty()
        #expect(session.state == .dirty)
        _ = await session.saveNow()
        #expect(spy.saveStarts == 1)
        #expect(session.state == .clean)
    }

    @Test func saveNowFromDirtyKeepsDirtyOnFailure() async {
        let spy = SaveSpy()
        spy.returnValue = false
        let session = makeSession(spy)
        session.markDirty()
        _ = await session.saveNow()
        #expect(spy.saveStarts == 1)
        #expect(session.state == .dirty)
    }

    @Test func markDirtyDuringSaveBecomesSavingDirty() async {
        let spy = SaveSpy()
        spy.gateNext()
        let session = makeSession(spy)

        // Kick off save in background; performSave is gated open until we release.
        async let saveTask: Bool = session.saveNow(force: true)
        // Yield a few times to ensure the save Task actually starts and hits the gate.
        for _ in 0..<5 { await Task.yield() }
        #expect(session.state == .saving)

        // Mark dirty during in-flight save — flips to savingDirty.
        session.markDirty()
        #expect(session.state == .savingDirty)

        // Release the gate and wait for save completion.
        spy.releasePending()
        let result = await saveTask
        #expect(result)

        // After save, transition back to .dirty (because edits happened
        // during save) and reschedule debounce.
        #expect(session.state == .dirty)
    }

    @Test func flushAndCloseClosesAndCallsFlush() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        session.markDirty()

        session.flushAndClose()
        #expect(session.state == .closed)

        // flushAndClose fires a fire-and-forget Task — give it time to run.
        for _ in 0..<20 { await Task.yield() }
        // Was dirty → final save + flush.
        #expect(spy.saveStarts == 1)
        #expect(spy.flushCalls == 1)
    }

    @Test func flushAndCloseSkipsSaveWhenClean() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        // Never marked dirty.
        session.flushAndClose()
        #expect(session.state == .closed)
        for _ in 0..<20 { await Task.yield() }
        #expect(spy.saveStarts == 0)
        #expect(spy.flushCalls == 1)
    }

    @Test func operationsAfterFlushAndCloseAreNoOp() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        session.flushAndClose()
        session.markDirty()
        #expect(session.state == .closed)
        let result = await session.saveNow(force: true)
        #expect(result)
        for _ in 0..<10 { await Task.yield() }
        // Only the flushAndClose flush; no further saves.
        #expect(spy.saveStarts == 0)
    }

    @Test func saveAfterMarkDirtyClearsDebounce() async {
        let spy = SaveSpy()
        let session = makeSession(spy)
        session.markDirty()
        _ = await session.saveNow() // explicit save consumes the debounce
        #expect(session.state == .clean)
        // After explicit save, no further save fires (debounce was cancelled).
        for _ in 0..<10 { await Task.yield() }
        #expect(spy.saveStarts == 1)
    }
}
