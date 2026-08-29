import Darwin
import Synchronization

/// Orders task cancellation against the lifetime of one synchronous socket operation.
///
/// Cancellation before `start(_:)` is recorded without touching a socket. Once `finish(_:)`
/// wins the lock, cancellation for that operation is stale and cannot affect a later operation.
final class HiredisSocketInterrupter: Sendable {
  struct Operation: Sendable, Equatable {
    fileprivate let identifier: UInt64
  }

  private enum OperationPhase: Sendable {
    case prepared
    case active
  }

  private struct ActiveOperation: Sendable {
    let operation: Operation
    var phase: OperationPhase = .prepared
    var isCancelled = false
    var didInterrupt = false
  }

  private struct State: Sendable {
    var descriptor: Int32?
    var nextOperationIdentifier: UInt64 = 0
    var activeOperation: ActiveOperation?
  }

  private let state = Mutex(State())
  private let shutdown: @Sendable (Int32) -> Void

  init(
    shutdown: @escaping @Sendable (Int32) -> Void = { descriptor in
      _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }
  ) {
    self.shutdown = shutdown
  }

  func install(_ descriptor: Int32) {
    state.withLock { state in
      precondition(state.descriptor == nil, "A socket descriptor is already installed")
      state.descriptor = descriptor
      interruptIfNeeded(state: &state)
    }
  }

  func clear() {
    state.withLock { $0.descriptor = nil }
  }

  func prepareOperation() -> Operation {
    state.withLock { state in
      precondition(state.activeOperation == nil, "A socket operation is already active")
      state.nextOperationIdentifier &+= 1
      let operation = Operation(identifier: state.nextOperationIdentifier)
      state.activeOperation = ActiveOperation(operation: operation)
      return operation
    }
  }

  func start(_ operation: Operation) -> Bool {
    state.withLock { state in
      guard var activeOperation = state.activeOperation,
        activeOperation.operation == operation
      else {
        preconditionFailure("The socket operation is no longer prepared")
      }
      precondition(
        activeOperation.phase == .prepared,
        "The socket operation has already started"
      )
      guard !activeOperation.isCancelled else { return false }
      activeOperation.phase = .active
      state.activeOperation = activeOperation
      return true
    }
  }

  func isCancelled(_ operation: Operation) -> Bool {
    state.withLock { state in
      guard let activeOperation = state.activeOperation,
        activeOperation.operation == operation
      else { return false }
      return activeOperation.isCancelled
    }
  }

  func finish(_ operation: Operation) -> Bool {
    state.withLock { state in
      guard let activeOperation = state.activeOperation,
        activeOperation.operation == operation
      else {
        preconditionFailure("The socket operation is no longer active")
      }
      state.activeOperation = nil
      return activeOperation.isCancelled
    }
  }

  func interrupt(_ operation: Operation) {
    state.withLock { state in
      guard var activeOperation = state.activeOperation,
        activeOperation.operation == operation
      else { return }
      activeOperation.isCancelled = true
      state.activeOperation = activeOperation
      interruptIfNeeded(state: &state)
    }
  }

  private func interruptIfNeeded(state: inout State) {
    guard var activeOperation = state.activeOperation,
      activeOperation.phase == .active,
      activeOperation.isCancelled,
      !activeOperation.didInterrupt,
      let descriptor = state.descriptor
    else { return }

    activeOperation.didInterrupt = true
    state.activeOperation = activeOperation
    shutdown(descriptor)
  }
}
