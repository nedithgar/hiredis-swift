import Darwin
import Dispatch
import Foundation
import Synchronization

struct MockExchange: Sendable {
  enum Action: Sendable {
    case reply(Data)
    case replyAfterCheckingForPipelining(Data, milliseconds: Int32)
    case echoArgumentAfterCheckingForPipelining(index: Int, milliseconds: Int32)
    case withholdReply
  }

  let expectedArguments: [Data]
  let action: Action
}

struct MockSession: Sendable {
  let exchanges: [MockExchange]

  init(_ exchanges: [MockExchange]) {
    self.exchanges = exchanges
  }
}

struct MockServerResult: Sendable, Equatable {
  let commandsBySession: [[[Data]]]
  let observedPipelining: Bool
}

enum MockServerError: Error, Sendable, CustomStringConvertible {
  case systemCall(name: String, code: Int32)
  case timedOut(String)
  case disconnected
  case malformedCommand(String)
  case commandMismatch(expected: [Data], actual: [Data])
  case unexpectedAdditionalData

  var description: String {
    switch self {
    case .systemCall(let name, let code): "\(name) failed with errno \(code)"
    case .timedOut(let operation): "Mock server timed out while waiting to \(operation)"
    case .disconnected: "Client disconnected before completing the script"
    case .malformedCommand(let reason): "Malformed command: \(reason)"
    case .commandMismatch(let expected, let actual):
      "Expected command \(expected), received \(actual)"
    case .unexpectedAdditionalData: "Client sent data after the scripted commands"
    }
  }
}

final class MockRESPServer: Sendable {
  let port: Int
  let commandEvents: AsyncStream<[Data]>

  private let sessions: [MockSession]
  private let sockets: MockSocketState
  private let queue = DispatchQueue(label: "dev.hiredis-swift.tests.mock-server")
  private let eventContinuation: AsyncStream<[Data]>.Continuation

  init(sessions: [MockSession]) throws {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else {
      throw MockServerError.systemCall(name: "socket", code: errno)
    }

    do {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = 0
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bindResult == 0 else {
        throw MockServerError.systemCall(name: "bind", code: errno)
      }
      guard Darwin.listen(listener, Int32(SOMAXCONN)) == 0 else {
        throw MockServerError.systemCall(name: "listen", code: errno)
      }

      var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.getsockname(listener, $0, &addressLength)
        }
      }
      guard nameResult == 0 else {
        throw MockServerError.systemCall(name: "getsockname", code: errno)
      }

      port = Int(UInt16(bigEndian: address.sin_port))
    } catch {
      Darwin.close(listener)
      throw error
    }

    self.sessions = sessions
    sockets = MockSocketState(listener: listener)
    let streamAndContinuation = AsyncStream<[Data]>.makeStream()
    commandEvents = streamAndContinuation.stream
    eventContinuation = streamAndContinuation.continuation
  }

  deinit {
    eventContinuation.finish()
    sockets.closeAll()
  }

  func run() async throws -> MockServerResult {
    let sessions = sessions
    let sockets = sockets
    let eventContinuation = eventContinuation
    let queue = queue

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            let result = try Self.runBlocking(
              sessions: sessions,
              sockets: sockets,
              eventContinuation: eventContinuation
            )
            eventContinuation.finish()
            continuation.resume(returning: result)
          } catch {
            eventContinuation.finish()
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      sockets.closeAll()
    }
  }

  private static func runBlocking(
    sessions: [MockSession],
    sockets: MockSocketState,
    eventContinuation: AsyncStream<[Data]>.Continuation
  ) throws -> MockServerResult {
    defer { sockets.closeAll() }

    var commandsBySession: [[[Data]]] = []
    var observedPipelining = false

    for session in sessions {
      let listener = try sockets.listener()
      try waitForReadability(
        descriptor: listener,
        milliseconds: 5_000,
        operation: "accept a connection"
      )

      let client = Darwin.accept(listener, nil, nil)
      guard client >= 0 else {
        throw MockServerError.systemCall(name: "accept", code: errno)
      }
      sockets.installClient(client)
      try configure(client: client)

      var buffer = Data()
      var sessionCommands: [[Data]] = []
      var shouldDrain = true

      for exchange in session.exchanges {
        let command = try readCommand(from: client, buffer: &buffer)
        sessionCommands.append(command)
        eventContinuation.yield(command)
        guard exchange.expectedArguments.isEmpty || command == exchange.expectedArguments else {
          throw MockServerError.commandMismatch(
            expected: exchange.expectedArguments,
            actual: command
          )
        }

        switch exchange.action {
        case .reply(let response):
          try send(response, to: client)
        case .replyAfterCheckingForPipelining(let response, let milliseconds):
          if !buffer.isEmpty || isReadable(descriptor: client, milliseconds: milliseconds) {
            observedPipelining = true
          }
          try send(response, to: client)
        case .echoArgumentAfterCheckingForPipelining(let index, let milliseconds):
          guard command.indices.contains(index) else {
            throw MockServerError.malformedCommand(
              "cannot echo missing argument at index \(index)"
            )
          }
          if !buffer.isEmpty || isReadable(descriptor: client, milliseconds: milliseconds) {
            observedPipelining = true
          }
          try send(RESPFixture.bulk(command[index]), to: client)
        case .withholdReply:
          try drainUntilEOF(from: client, initialBuffer: buffer)
          buffer.removeAll(keepingCapacity: false)
          shouldDrain = false
        }

        if case .withholdReply = exchange.action {
          break
        }
      }

      if shouldDrain {
        try drainUntilEOF(from: client, initialBuffer: buffer)
      }
      commandsBySession.append(sessionCommands)
      sockets.closeClient()
    }

    return MockServerResult(
      commandsBySession: commandsBySession,
      observedPipelining: observedPipelining
    )
  }

  private static func configure(client: Int32) throws {
    var noSignal = Int32(1)
    guard
      Darwin.setsockopt(
        client,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal))
      ) == 0
    else {
      throw MockServerError.systemCall(name: "setsockopt(SO_NOSIGPIPE)", code: errno)
    }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard
      Darwin.setsockopt(
        client,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout.size(ofValue: timeout))
      ) == 0
    else {
      throw MockServerError.systemCall(name: "setsockopt(SO_RCVTIMEO)", code: errno)
    }
  }

  private static func waitForReadability(
    descriptor: Int32,
    milliseconds: Int32,
    operation: String
  ) throws {
    var descriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
      let result = Darwin.poll(&descriptor, 1, milliseconds)
      if result > 0 { return }
      if result == 0 { throw MockServerError.timedOut(operation) }
      if errno != EINTR {
        throw MockServerError.systemCall(name: "poll", code: errno)
      }
    }
  }

  private static func isReadable(descriptor: Int32, milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
      let result = Darwin.poll(&descriptor, 1, milliseconds)
      if result >= 0 { return result > 0 }
      if errno != EINTR { return false }
    }
  }

  private static func readCommand(
    from descriptor: Int32,
    buffer: inout Data
  ) throws -> [Data] {
    while true {
      if let parsed = try parseCommand(buffer) {
        buffer.removeFirst(parsed.consumed)
        return parsed.arguments
      }

      var incoming = [UInt8](repeating: 0, count: 4_096)
      let received = incoming.withUnsafeMutableBytes { bytes in
        Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if received > 0 {
        buffer.append(contentsOf: incoming.prefix(received))
        guard buffer.count <= 1_048_576 else {
          throw MockServerError.malformedCommand("command exceeds the 1 MiB test limit")
        }
        continue
      }
      if received == 0 { throw MockServerError.disconnected }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        throw MockServerError.timedOut("read a command")
      }
      throw MockServerError.systemCall(name: "recv", code: errno)
    }
  }

  private static func parseCommand(_ data: Data) throws -> (arguments: [Data], consumed: Int)? {
    let bytes = [UInt8](data)
    guard !bytes.isEmpty else { return nil }
    guard bytes[0] == Character("*").asciiValue else {
      throw MockServerError.malformedCommand("expected an array prefix")
    }
    guard let firstLineEnd = crlf(in: bytes, startingAt: 1) else { return nil }
    guard let count = decimal(bytes[(1..<firstLineEnd)]), count >= 0 else {
      throw MockServerError.malformedCommand("invalid argument count")
    }

    var cursor = firstLineEnd + 2
    var arguments: [Data] = []
    arguments.reserveCapacity(count)

    for _ in 0..<count {
      guard cursor < bytes.count else { return nil }
      guard bytes[cursor] == Character("$").asciiValue else {
        throw MockServerError.malformedCommand("expected a bulk-string argument")
      }
      guard let lengthLineEnd = crlf(in: bytes, startingAt: cursor + 1) else { return nil }
      guard let length = decimal(bytes[((cursor + 1)..<lengthLineEnd)]), length >= 0 else {
        throw MockServerError.malformedCommand("invalid argument length")
      }
      cursor = lengthLineEnd + 2
      guard length <= bytes.count - cursor else { return nil }
      let argumentEnd = cursor + length
      guard argumentEnd + 2 <= bytes.count else { return nil }
      guard bytes[argumentEnd] == 13, bytes[argumentEnd + 1] == 10 else {
        throw MockServerError.malformedCommand("argument is missing CRLF")
      }
      arguments.append(Data(bytes[cursor..<argumentEnd]))
      cursor = argumentEnd + 2
    }

    return (arguments, cursor)
  }

  private static func crlf(in bytes: [UInt8], startingAt start: Int) -> Int? {
    guard start < bytes.count else { return nil }
    for index in start..<(bytes.count - 1) where bytes[index] == 13 && bytes[index + 1] == 10 {
      return index
    }
    return nil
  }

  private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
    String(bytes: bytes, encoding: .ascii).flatMap(Int.init)
  }

  private static func send(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let result = Darwin.send(
          descriptor,
          bytes.baseAddress!.advanced(by: sent),
          bytes.count - sent,
          0
        )
        if result > 0 {
          sent += result
        } else if result < 0, errno == EINTR {
          continue
        } else {
          throw MockServerError.systemCall(name: "send", code: errno)
        }
      }
    }
  }

  private static func drainUntilEOF(from descriptor: Int32, initialBuffer: Data) throws {
    guard initialBuffer.isEmpty else {
      throw MockServerError.unexpectedAdditionalData
    }

    var storage = [UInt8](repeating: 0, count: 1_024)
    while true {
      let received = storage.withUnsafeMutableBytes { bytes in
        Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if received == 0 { return }
      if received > 0 { throw MockServerError.unexpectedAdditionalData }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        throw MockServerError.timedOut("observe the client closing")
      }
      if errno == ECONNRESET { return }
      throw MockServerError.systemCall(name: "recv", code: errno)
    }
  }
}

private struct MockDescriptors: Sendable {
  var listener: Int32?
  var client: Int32?
}

private final class MockSocketState: Sendable {
  private let descriptors: Mutex<MockDescriptors>

  init(listener: Int32) {
    descriptors = Mutex(MockDescriptors(listener: listener, client: nil))
  }

  func listener() throws -> Int32 {
    try descriptors.withLock { descriptors in
      guard let listener = descriptors.listener else {
        throw MockServerError.disconnected
      }
      return listener
    }
  }

  func installClient(_ client: Int32) {
    descriptors.withLock { $0.client = client }
  }

  func closeClient() {
    descriptors.withLock { descriptors in
      guard let client = descriptors.client else { return }
      _ = Darwin.shutdown(client, SHUT_RDWR)
      Darwin.close(client)
      descriptors.client = nil
    }
  }

  func closeAll() {
    descriptors.withLock { descriptors in
      if let client = descriptors.client {
        _ = Darwin.shutdown(client, SHUT_RDWR)
        Darwin.close(client)
        descriptors.client = nil
      }
      if let listener = descriptors.listener {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        descriptors.listener = nil
      }
    }
  }
}

enum RESPFixture {
  static func status(_ value: String) -> Data {
    Data("+\(value)\r\n".utf8)
  }

  static func error(_ value: String) -> Data {
    Data("-\(value)\r\n".utf8)
  }

  static func bulk(_ value: Data) -> Data {
    var data = Data("$\(value.count)\r\n".utf8)
    data.append(value)
    data.append(Data("\r\n".utf8))
    return data
  }
}
