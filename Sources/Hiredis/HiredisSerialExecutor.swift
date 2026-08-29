import Dispatch

final class HiredisSerialExecutor: SerialExecutor {
  private let queue: DispatchQueue

  init(label: String) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedJob(job)
    let executor = asUnownedSerialExecutor()
    queue.async {
      unownedJob.runSynchronously(on: executor)
    }
  }
}
