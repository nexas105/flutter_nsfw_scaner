import Foundation
import os

/// Minimal iOS 15-compatible stand-in for `OSAllocatedUnfairLock` (iOS 16+).
///
/// Same surface as the subset of the system type this plugin uses:
/// `withLock`, `withLockUnchecked`, `lock()` / `unlock()`, `lockIfAvailable()`
/// and the `State == Void` convenience init. Backed by a heap-allocated
/// `os_unfair_lock` so the lock never moves (storing `os_unfair_lock` inline
/// in a struct is undefined behaviour — the class + pointer pair avoids that).
final class UnfairLock<State>: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>
    private var state: State

    init(initialState: State) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        state = initialState
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
    func lockIfAvailable() -> Bool { os_unfair_lock_trylock(pointer) }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(pointer); defer { os_unfair_lock_unlock(pointer) }
        return try body(&state)
    }

    func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}

extension UnfairLock where State == Void {
    convenience init() { self.init(initialState: ()) }

    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(pointer); defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }

    func withLockUnchecked<R>(_ body: () throws -> R) rethrows -> R {
        try withLock(body)
    }
}
