import Foundation

// MARK: - Undo/redo with gesture coalescing
//
// Slider drags fire dozens of updates per second; each burst should be ONE
// undo step. Edits arriving within `coalesceInterval` of the previous edit
// are treated as the same gesture: the state before the gesture's first
// edit is what undo restores.

final class EditHistory<State: Equatable> {
    private(set) var undoStack: [State] = []
    private(set) var redoStack: [State] = []
    /// Most recent state seen (end of the last recorded edit).
    private var latest: State
    private var lastEditAt: Date?
    private let coalesceInterval: TimeInterval
    private let limit: Int

    init(initial: State, coalesceInterval: TimeInterval = 0.8, limit: Int = 100) {
        self.latest = initial
        self.coalesceInterval = coalesceInterval
        self.limit = limit
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call after every mutation with the post-mutation state.
    func recordEdit(_ current: State, at now: Date = Date()) {
        let sameGesture = lastEditAt.map {
            now.timeIntervalSince($0) < coalesceInterval
        } ?? false
        if !sameGesture, current != latest {
            undoStack.append(latest)
            if undoStack.count > limit { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        latest = current
        lastEditAt = now
    }

    /// Returns the state to restore, or nil if nothing to undo.
    func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        latest = previous
        lastEditAt = nil
        return previous
    }

    /// Returns the state to restore, or nil if nothing to redo.
    func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        latest = next
        lastEditAt = nil
        return next
    }
}
