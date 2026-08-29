import CHiredis
import Foundation

enum HiredisCommandArguments {
  static func withUnsafeArguments<Result>(
    _ arguments: [Data],
    _ body: (
      UnsafeMutablePointer<UnsafePointer<CChar>?>?,
      UnsafePointer<Int>?
    ) throws -> Result
  ) rethrows -> Result {
    var allocations: [UnsafeMutablePointer<CChar>] = []
    allocations.reserveCapacity(arguments.count)
    defer {
      for allocation in allocations {
        allocation.deallocate()
      }
    }

    var pointers: [UnsafePointer<CChar>?] = []
    var lengths: [Int] = []
    pointers.reserveCapacity(arguments.count)
    lengths.reserveCapacity(arguments.count)

    for argument in arguments {
      let allocation = UnsafeMutablePointer<CChar>.allocate(capacity: max(argument.count, 1))
      allocations.append(allocation)
      if !argument.isEmpty {
        argument.withUnsafeBytes { bytes in
          UnsafeMutableRawPointer(allocation).copyMemory(
            from: bytes.baseAddress!,
            byteCount: bytes.count
          )
        }
      }
      pointers.append(UnsafePointer(allocation))
      lengths.append(argument.count)
    }

    return try pointers.withUnsafeMutableBufferPointer { pointerBuffer in
      try lengths.withUnsafeBufferPointer { lengthBuffer in
        try body(pointerBuffer.baseAddress, lengthBuffer.baseAddress)
      }
    }
  }
}
