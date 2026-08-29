import Synchronization
import Testing

@testable import Hiredis

@Suite("Socket interruption coordination")
struct SocketInterrupterTests {
  @Test("Cancellation before activation does not touch an installed socket")
  func cancellationBeforeActivation() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    interrupter.install(101)
    let operation = interrupter.prepareOperation()

    interrupter.interrupt(operation)

    #expect(!interrupter.start(operation))
    #expect(interrupter.finish(operation))
    #expect(recorder.descriptors.isEmpty)
  }

  @Test("Cancellation during an active operation interrupts exactly once")
  func cancellationDuringActiveOperation() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    interrupter.install(102)
    let operation = interrupter.prepareOperation()
    #expect(interrupter.start(operation))

    interrupter.interrupt(operation)
    interrupter.interrupt(operation)

    #expect(interrupter.finish(operation))
    #expect(recorder.descriptors == [102])
  }

  @Test("A descriptor installed after cancellation is interrupted before use")
  func descriptorInstalledAfterCancellation() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    let operation = interrupter.prepareOperation()
    #expect(interrupter.start(operation))

    interrupter.interrupt(operation)
    #expect(recorder.descriptors.isEmpty)
    interrupter.install(103)

    #expect(interrupter.finish(operation))
    #expect(recorder.descriptors == [103])
  }

  @Test("Completion wins over cancellation after the operation finishes")
  func completionBeforeCancellation() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    interrupter.install(104)
    let operation = interrupter.prepareOperation()
    #expect(interrupter.start(operation))
    #expect(!interrupter.finish(operation))

    interrupter.interrupt(operation)

    #expect(recorder.descriptors.isEmpty)
  }

  @Test("A stale cancellation cannot interrupt the next operation")
  func staleCancellationCannotInterruptNextOperation() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    interrupter.install(105)
    let completedOperation = interrupter.prepareOperation()
    #expect(interrupter.start(completedOperation))
    #expect(!interrupter.finish(completedOperation))

    let currentOperation = interrupter.prepareOperation()
    #expect(interrupter.start(currentOperation))
    interrupter.interrupt(completedOperation)

    #expect(!interrupter.finish(currentOperation))
    #expect(recorder.descriptors.isEmpty)
  }

  @Test("Clearing the descriptor prevents cancellation from using stale storage")
  func clearedDescriptorIsNotInterrupted() {
    let recorder = ShutdownRecorder()
    let interrupter = makeInterrupter(recorder: recorder)
    interrupter.install(106)
    let operation = interrupter.prepareOperation()
    #expect(interrupter.start(operation))
    interrupter.clear()

    interrupter.interrupt(operation)

    #expect(interrupter.finish(operation))
    #expect(recorder.descriptors.isEmpty)
  }

  private func makeInterrupter(
    recorder: ShutdownRecorder
  ) -> HiredisSocketInterrupter {
    HiredisSocketInterrupter { descriptor in
      recorder.record(descriptor)
    }
  }
}

private final class ShutdownRecorder: Sendable {
  private let storage = Mutex<[Int32]>([])

  var descriptors: [Int32] {
    storage.withLock { $0 }
  }

  func record(_ descriptor: Int32) {
    storage.withLock { $0.append(descriptor) }
  }
}
