import Foundation

// MARK: - Retain tree

/// A node in the retain tree produced by `buildRetainTree(during:)`.
/// Each node holds the identifiers of objects retained at its call level
/// and zero or more child nodes from nested `buildRetainTree` calls.
public final class RetainTreeNode: CustomStringConvertible {
    public fileprivate(set) var identifiers: [ObjectIdentifier] = []
    public fileprivate(set) var children: [RetainTreeNode] = []

    public var description: String { format(indent: 0) }

    private func format(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad) retains: \(identifiers)"]
        for child in children {
            lines.append(child.format(indent: indent + 1))
        }
        return lines.joined(separator: "\n")
    }
}

// Stack of nodes currently being built. The top element is the active node
// that the C retain callback writes into.  A file-private global (not a
// local variable) can be accessed from a non-capturing C function pointer.
private var _retainTreeStack: [RetainTreeNode] = []

/// Executes `closure` and returns a tree of `ObjectIdentifier`s collected
/// from every ARC retain that occurred during execution.
///
/// `buildRetainTree` can be called recursively inside the closure — each
/// nested invocation creates a child node, so the tree mirrors the
/// hierarchical call structure.
///
/// ```swift
/// let tree = buildRetainTree {
///     doWork()                    // retains → root node
///     buildRetainTree {
///         doMoreWork()            // retains → first child node
///         buildRetainTree {
///             doEvenMore()        // retains → grandchild node
///         }
///     }
/// }
/// print(tree)
/// // retains: 5
/// //   retains: 3
/// //     retains: 1
/// ```
@discardableResult
func buildRetainTree(during closure: () -> Void) -> RetainTreeNode {
    let node = RetainTreeNode()

    // Register as a child of the current parent (if nested).
    _retainTreeStack.last?.children.append(node)
    _retainTreeStack.append(node)

    let isRoot = _retainTreeStack.count == 1

    if isRoot {
        // Install once; set the single persistent callback.
        // The callback routes each retain to whatever node is on top of
        // the stack — this automatically handles any nesting depth.
        RetainHookInstall()
        RetainHookBegin { rawPtr in
            guard let ptr = rawPtr,
                  let current = _retainTreeStack.last else { return }
            current.identifiers.append(unsafeBitCast(ptr, to: ObjectIdentifier.self))
        }
    }
    // Non-root calls skip RetainHookBegin: the same callback is already
    // active and will start writing to the new top-of-stack automatically.

    autoreleasepool { closure() }

    _retainTreeStack.removeLast()

    // Only the root tears the hook down; nested unwinds leave it running
    // so the parent level continues to collect after the child returns.
    if isRoot { RetainHookEnd() }

    return node
}

// Global buffer for the C retain hook callback.
// A global (not a local) is not a "capture", so a closure that only
// reads/writes this can be passed as a bare C function pointer.
private var _retainHookBuffer: [ObjectIdentifier] = []

/// Executes `closure` and returns the `ObjectIdentifier` of every object
/// that was retained (via `objc_retain` / `swift_retain`) during its execution.
///
/// The collection is driven by a C-level fishhook on the ARC retain functions,
/// so every retain — including ones the closure itself never mentions
/// explicitly — is captured automatically.
///
/// Usage:
/// ```swift
/// let ids = collectRetainedIdentifiers {
///     someCache.store(MyObject()) // retain captured transparently
/// }
/// ```
@discardableResult
func collectRetainedIdentifiers(during closure: () -> Void) -> [ObjectIdentifier] {
    RetainHookInstall()
    _retainHookBuffer.removeAll()

    // This closure captures nothing (accesses only the file-level global
    // _retainHookBuffer), so Swift can form a C function pointer from it.
    RetainHookBegin { rawPtr in
        guard let ptr = rawPtr else { return }
        _retainHookBuffer.append(unsafeBitCast(ptr, to: ObjectIdentifier.self))
    }

    autoreleasepool { closure() }
    RetainHookEnd()

    defer { _retainHookBuffer.removeAll() }
    return _retainHookBuffer
}
