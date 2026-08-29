import Foundation
import Testing

@testable import Hiredis

@Suite("Live connection behavior")
struct ConnectionTests {
  @Test("PING and raw commands use binary-safe argv framing")
  func pingAndBinaryCommand() async throws {
    let binaryValue = Data([0x61, 0x00, 0x62, 0x00, 0x63])
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("PING".utf8)],
          action: .reply(RESPFixture.status("PONG"))
        ),
        MockExchange(
          expectedArguments: [Data("ECHO".utf8), binaryValue],
          action: .reply(RESPFixture.bulk(binaryValue))
        ),
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)

    try await connection.connect()
    #expect(try await connection.ping() == "PONG")
    let response = try await connection.command(arguments: [Data("ECHO".utf8), binaryValue])
    #expect(response.reply == .bulkString(binaryValue))
    await connection.close()

    let result = try await serverResult
    #expect(result.commandsBySession.count == 1)
    #expect(result.commandsBySession[0].count == 2)
  }

  @Test("RESP3 attributes and pushes are retained with the command reply")
  func resp3Metadata() async throws {
    var metadataReply = Data("|1\r\n+ttl\r\n:30\r\n".utf8)
    metadataReply.append(Data(">2\r\n+message\r\n$5\r\nhello\r\n".utf8))
    metadataReply.append(RESPFixture.status("OK"))

    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("HELLO".utf8), Data("3".utf8)],
          action: .reply(Data("%1\r\n+server\r\n+redis\r\n".utf8))
        ),
        MockExchange(
          expectedArguments: [Data("COMMAND".utf8)],
          action: .reply(metadataReply)
        ),
      ])
    ])
    async let serverResult = server.run()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      protocolVersion: .resp3
    )
    let connection = HiredisConnection(configuration: configuration)

    try await connection.connect()
    let response = try await connection.command(arguments: [Data("COMMAND".utf8)])
    #expect(response.reply == .status("OK"))
    #expect(
      response.attributes == [
        HiredisMapEntry(key: .status("ttl"), value: .integer(30))
      ]
    )
    #expect(
      response.pushMessages == [
        [
          .status("message"),
          .bulkString(Data("hello".utf8)),
        ]
      ]
    )
    await connection.close()
    _ = try await serverResult
  }

  @Test("Reconnect creates a fresh context and repeats the handshake")
  func reconnectRepeatsHandshake() async throws {
    let username = Data("application".utf8)
    let password = Data("secret".utf8)
    let handshake = [
      MockExchange(
        expectedArguments: [Data("AUTH".utf8), username, password],
        action: .reply(RESPFixture.status("OK"))
      ),
      MockExchange(
        expectedArguments: [Data("SELECT".utf8), Data("2".utf8)],
        action: .reply(RESPFixture.status("OK"))
      ),
      MockExchange(
        expectedArguments: [Data("PING".utf8)],
        action: .reply(RESPFixture.status("PONG"))
      ),
    ]
    let server = try MockRESPServer(sessions: [MockSession(handshake), MockSession(handshake)])
    async let serverResult = server.run()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      username: String(decoding: username, as: UTF8.self),
      password: String(decoding: password, as: UTF8.self),
      database: 2
    )
    let connection = HiredisConnection(configuration: configuration)

    try await connection.connect()
    #expect(try await connection.ping() == "PONG")
    try await connection.reconnect()
    #expect(try await connection.ping() == "PONG")
    await connection.close()

    let result = try await serverResult
    #expect(result.commandsBySession.count == 2)
    #expect(result.commandsBySession[0] == result.commandsBySession[1])
  }

  @Test("Close is idempotent and rejects later commands")
  func closeAndInvalidLifetime() async throws {
    let server = try MockRESPServer(sessions: [MockSession([])])
    async let serverResult = server.run()
    let connection = try connection(to: server)

    try await connection.connect()
    #expect(await connection.isConnected)
    await connection.close()
    #expect(!(await connection.isConnected))
    await connection.close()

    await #expect(throws: HiredisError.invalidLifetime(.notConnected)) {
      try await connection.command(arguments: [Data("PING".utf8)])
    }
    _ = try await serverResult
  }

  @Test("Connect rejects an already-open connection")
  func duplicateConnect() async throws {
    let server = try MockRESPServer(sessions: [MockSession([])])
    async let serverResult = server.run()
    let connection = try connection(to: server)

    try await connection.connect()
    await #expect(throws: HiredisError.invalidLifetime(.alreadyConnected)) {
      try await connection.connect()
    }
    await connection.close()
    _ = try await serverResult
  }

  @Test("Deinitialization closes and releases an open context")
  func deinitializationClosesConnection() async throws {
    let server = try MockRESPServer(sessions: [MockSession([])])
    async let serverResult = server.run()
    var connection: HiredisConnection? = try connection(to: server)
    weak let weakConnection = connection

    try await connection?.connect()
    #expect(await connection?.isConnected == true)
    connection = nil

    _ = try await serverResult
    #expect(weakConnection == nil)
  }

  @Test("A command timeout closes the unusable context")
  func commandTimeout() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("BLOCK".utf8)],
          action: .withholdReply
        )
      ])
    ])
    async let serverResult = server.run()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      commandTimeout: .milliseconds(150)
    )
    let connection = HiredisConnection(configuration: configuration)

    try await connection.connect()
    await #expect(throws: HiredisError.timeout(.command)) {
      try await connection.command(arguments: [Data("BLOCK".utf8)])
    }
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("Cancellation interrupts blocking I/O and closes the context")
  func cancellation() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("BLOCK".utf8)],
          action: .withholdReply
        )
      ])
    ])
    async let serverResult = server.run()
    var commandEvents = server.commandEvents.makeAsyncIterator()
    let connection = try connection(to: server, commandTimeout: .seconds(4))

    try await connection.connect()
    let task = Task {
      try await connection.command(arguments: [Data("BLOCK".utf8)])
    }
    let observedCommand = await commandEvents.next()
    #expect(observedCommand == [Data("BLOCK".utf8)])

    task.cancel()
    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("Cancellation interrupts a blocking connection handshake")
  func connectCancellationDuringHandshake() async throws {
    let username = Data("application".utf8)
    let password = Data("secret".utf8)
    let authentication = [Data("AUTH".utf8), username, password]
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: authentication,
          action: .withholdReply
        )
      ])
    ])
    async let serverResult = server.run()
    var commandEvents = server.commandEvents.makeAsyncIterator()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      username: String(decoding: username, as: UTF8.self),
      password: String(decoding: password, as: UTF8.self),
      commandTimeout: .seconds(4)
    )
    let connection = HiredisConnection(configuration: configuration)
    let task = Task {
      try await connection.connect()
    }

    #expect(await commandEvents.next() == authentication)
    task.cancel()

    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("Cancellation interrupts a blocking reconnect handshake")
  func reconnectCancellationDuringHandshake() async throws {
    let username = Data("application".utf8)
    let password = Data("secret".utf8)
    let authentication = [Data("AUTH".utf8), username, password]
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: authentication,
          action: .reply(RESPFixture.status("OK"))
        )
      ]),
      MockSession([
        MockExchange(
          expectedArguments: authentication,
          action: .withholdReply
        )
      ]),
    ])
    async let serverResult = server.run()
    var commandEvents = server.commandEvents.makeAsyncIterator()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      username: String(decoding: username, as: UTF8.self),
      password: String(decoding: password, as: UTF8.self),
      commandTimeout: .seconds(4)
    )
    let connection = HiredisConnection(configuration: configuration)
    try await connection.connect()
    #expect(await commandEvents.next() == authentication)

    let task = Task {
      try await connection.reconnect()
    }
    #expect(await commandEvents.next() == authentication)
    task.cancel()

    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("An already-cancelled connect maps cancellation without opening a context")
  func alreadyCancelledConnect() async throws {
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: 1,
      connectionTimeout: .seconds(2)
    )
    let connection = HiredisConnection(configuration: configuration)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await connection.connect()
    }

    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }
    #expect(!(await connection.isConnected))
  }

  @Test("An already-cancelled command leaves the existing connection usable")
  func alreadyCancelledCommand() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("PING".utf8)],
          action: .reply(RESPFixture.status("PONG"))
        )
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)
    try await connection.connect()

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await connection.command(arguments: [Data("UNSENT".utf8)])
    }
    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }

    #expect(await connection.isConnected)
    #expect(try await connection.ping() == "PONG")
    await connection.close()

    let result = try await serverResult
    #expect(result.commandsBySession == [[[Data("PING".utf8)]]])
  }

  @Test("An already-cancelled reconnect preserves the current connection")
  func alreadyCancelledReconnect() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("PING".utf8)],
          action: .reply(RESPFixture.status("PONG"))
        )
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)
    try await connection.connect()

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await connection.reconnect()
    }
    await #expect(throws: HiredisError.cancellation) {
      try await task.value
    }

    #expect(await connection.isConnected)
    #expect(try await connection.ping() == "PONG")
    await connection.close()

    let result = try await serverResult
    #expect(result.commandsBySession == [[[Data("PING".utf8)]]])
  }

  @Test("Concurrent callers never pipeline work on one hiredis context")
  func concurrentCallsAreSerialized() async throws {
    let count = 8
    let exchanges = (0..<count).map { _ in
      return MockExchange(
        expectedArguments: [],
        action: .echoArgumentAfterCheckingForPipelining(
          index: 1,
          milliseconds: 40
        )
      )
    }
    let server = try MockRESPServer(sessions: [MockSession(exchanges)])
    async let serverResult = server.run()
    let connection = try connection(to: server)
    try await connection.connect()

    let replies = try await withThrowingTaskGroup(
      of: (Int, HiredisReply).self,
      returning: [Int: HiredisReply].self
    ) { group in
      for index in 0..<count {
        group.addTask {
          let value = Data(String(index).utf8)
          let response = try await connection.command(
            arguments: [Data("ECHO".utf8), value]
          )
          return (index, response.reply)
        }
      }

      var replies: [Int: HiredisReply] = [:]
      for try await (index, reply) in group {
        replies[index] = reply
      }
      return replies
    }

    for index in 0..<count {
      #expect(replies[index] == .bulkString(Data(String(index).utf8)))
    }
    await connection.close()
    let result = try await serverResult
    #expect(!result.observedPipelining)
    #expect(result.commandsBySession[0].count == count)
    #expect(
      result.commandsBySession[0].allSatisfy { command in
        command.count == 2 && command[0] == Data("ECHO".utf8)
      })
  }

  @Test("Server reply errors are structured and leave the socket usable")
  func serverReplyError() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("GET".utf8), Data("key".utf8)],
          action: .reply(RESPFixture.error("WRONGTYPE incompatible value"))
        )
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)

    try await connection.connect()
    await #expect(
      throws: HiredisError.serverReply(
        HiredisServerError(code: "WRONGTYPE", message: "incompatible value")
      )
    ) {
      try await connection.command(
        arguments: [Data("GET".utf8), Data("key".utf8)]
      )
    }
    #expect(await connection.isConnected)
    await connection.close()
    _ = try await serverResult
  }

  @Test("Protocol errors close the invalid context")
  func protocolError() async throws {
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("BROKEN".utf8)],
          action: .reply(Data("?not-resp\r\n".utf8))
        )
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)

    try await connection.connect()
    do {
      _ = try await connection.command(arguments: [Data("BROKEN".utf8)])
      Issue.record("Malformed server data unexpectedly parsed")
    } catch let error as HiredisError {
      guard case .protocolFailure = error else {
        Issue.record("Expected a protocol failure, got \(error)")
        return
      }
    }
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("Configured credentials never appear in authentication failures")
  func configuredCredentialRedaction() async throws {
    let username = "private-user"
    let password = "private-password"
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [
            Data("AUTH".utf8),
            Data(username.utf8),
            Data(password.utf8),
          ],
          action: .reply(
            RESPFixture.error("ERR rejected \(username) using \(password)")
          )
        )
      ])
    ])
    async let serverResult = server.run()
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      username: username,
      password: password
    )
    let connection = HiredisConnection(configuration: configuration)

    let description = await capturedErrorDescription {
      try await connection.connect()
    }
    #expect(!description.contains(username))
    #expect(!description.contains(password))
    #expect(description.contains("<redacted>"))
    #expect(!(await connection.isConnected))
    _ = try await serverResult
  }

  @Test("Raw AUTH arguments never appear in server errors")
  func rawAuthenticationRedaction() async throws {
    let password = "command-password"
    let server = try MockRESPServer(sessions: [
      MockSession([
        MockExchange(
          expectedArguments: [Data("AUTH".utf8), Data(password.utf8)],
          action: .reply(RESPFixture.error("ERR rejected AUTH \(password)"))
        )
      ])
    ])
    async let serverResult = server.run()
    let connection = try connection(to: server)
    try await connection.connect()

    let description = await capturedErrorDescription {
      try await connection.command(
        arguments: [Data("AUTH".utf8), Data(password.utf8)]
      )
    }
    #expect(!description.contains(password))
    #expect(description.contains("<redacted>"))
    await connection.close()
    _ = try await serverResult
  }

  private func connection(
    to server: MockRESPServer,
    commandTimeout: Duration = .seconds(2)
  ) throws -> HiredisConnection {
    let configuration = try HiredisConfiguration(
      hostname: "127.0.0.1",
      port: server.port,
      connectionTimeout: .seconds(2),
      commandTimeout: commandTimeout
    )
    return HiredisConnection(configuration: configuration)
  }

  private func capturedErrorDescription<Result: Sendable>(
    _ operation: () async throws -> Result
  ) async -> String {
    do {
      _ = try await operation()
      Issue.record("Expected the operation to throw")
      return ""
    } catch {
      return String(describing: error)
    }
  }
}
