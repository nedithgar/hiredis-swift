import Foundation
import Hiredis
import Testing

extension Tag {
  @Tag static var redisIntegration: Self
}

@Suite(
  "GitHub Actions Redis integration",
  .enabled(
    if: RedisIntegrationEnvironment.shouldRun,
    "Requires the dedicated GitHub Actions Redis Integration workflow; local runs intentionally skip it without installing or contacting Redis."
  ),
  .tags(.redisIntegration)
)
struct RedisIntegrationTests: Sendable {
  @Test(
    "Authenticates, negotiates RESP, and reconnects",
    arguments: HiredisProtocolVersion.allCases,
    AuthenticationMode.allCases
  )
  func authenticatedHandshake(
    protocolVersion: HiredisProtocolVersion,
    authenticationMode: AuthenticationMode
  ) async throws {
    try await withConnection(
      protocolVersion: protocolVersion,
      authenticationMode: authenticationMode
    ) { connection in
      #expect(try await connection.ping() == "PONG")

      try await connection.reconnect()
      #expect(try await connection.ping() == "PONG")
    }
  }

  @Test("Preserves binary values and applies database selection")
  func binaryRoundTripAndDatabaseSelection() async throws {
    let key = Data("hiredis-swift:integration:binary:\(UUID().uuidString)".utf8)
    let value = Data([0x00, 0x41, 0x00, 0x42, 0xFF])

    try await withConnection(protocolVersion: .resp3, database: 1) { databaseOne in
      let setResponse = try await databaseOne.command(arguments: [
        Data("SET".utf8), key, value,
      ])
      #expect(setResponse.reply == .status("OK"))

      let getResponse = try await databaseOne.command(arguments: [
        Data("GET".utf8), key,
      ])
      #expect(getResponse.reply == .bulkString(value))

      try await withConnection(protocolVersion: .resp3) { databaseZero in
        let isolatedResponse = try await databaseZero.command(arguments: [
          Data("GET".utf8), key,
        ])
        #expect(isolatedResponse.reply == .null)
      }

      let deleteResponse = try await databaseOne.command(arguments: [
        Data("DEL".utf8), key,
      ])
      #expect(deleteResponse.reply == .integer(1))
    }
  }

  @Test("Decodes a map emitted by a real RESP3 server")
  func realRESP3Map() async throws {
    let key = Data("hiredis-swift:integration:map:\(UUID().uuidString)".utf8)
    let fieldOne = Data("first".utf8)
    let valueOne = Data("alpha".utf8)
    let fieldTwo = Data("second".utf8)
    let valueTwo = Data([0x62, 0x00, 0x63])

    try await withConnection(protocolVersion: .resp3) { connection in
      let insertResponse = try await connection.command(arguments: [
        Data("HSET".utf8), key,
        fieldOne, valueOne,
        fieldTwo, valueTwo,
      ])
      #expect(insertResponse.reply == .integer(2))

      let response = try await connection.command(arguments: [
        Data("HGETALL".utf8), key,
      ])
      guard case .map(let entries) = response.reply else {
        Issue.record("Expected a RESP3 map from HGETALL, got \(response.reply)")
        return
      }

      #expect(entries.count == 2)
      #expect(
        entries.contains(
          HiredisMapEntry(key: .bulkString(fieldOne), value: .bulkString(valueOne))
        )
      )
      #expect(
        entries.contains(
          HiredisMapEntry(key: .bulkString(fieldTwo), value: .bulkString(valueTwo))
        )
      )

      _ = try await connection.command(arguments: [Data("DEL".utf8), key])
    }
  }

  @Test("Maps a real server error without invalidating the connection")
  func realServerError() async throws {
    let key = Data("hiredis-swift:integration:error:\(UUID().uuidString)".utf8)

    try await withConnection(protocolVersion: .resp3) { connection in
      _ = try await connection.command(arguments: [
        Data("SET".utf8), key, Data("plain-value".utf8),
      ])

      do {
        _ = try await connection.command(arguments: [
          Data("HGETALL".utf8), key,
        ])
        Issue.record("HGETALL unexpectedly accepted a string value")
      } catch HiredisError.serverReply(let serverError) {
        #expect(serverError.code == "WRONGTYPE")
        #expect(!serverError.message.isEmpty)
      } catch {
        Issue.record("Expected a structured Redis server error, got \(error)")
      }

      #expect(await connection.isConnected)
      #expect(try await connection.ping() == "PONG")
      _ = try await connection.command(arguments: [Data("DEL".utf8), key])
    }
  }

  private func withConnection<Result: Sendable>(
    protocolVersion: HiredisProtocolVersion,
    database: Int = 0,
    authenticationMode: AuthenticationMode = .defaultUser,
    _ operation: @Sendable (HiredisConnection) async throws -> Result
  ) async throws -> Result {
    let server = try RedisIntegrationEnvironment.server()
    let configuration = try HiredisConfiguration(
      hostname: server.hostname,
      port: server.port,
      username: authenticationMode.username,
      password: server.password,
      database: database,
      connectionTimeout: .seconds(5),
      commandTimeout: .seconds(5),
      protocolVersion: protocolVersion
    )
    let connection = HiredisConnection(configuration: configuration)

    try await connection.connect()
    do {
      let result = try await operation(connection)
      await connection.close()
      return result
    } catch {
      await connection.close()
      throw error
    }
  }
}

enum AuthenticationMode: String, CaseIterable, Sendable {
  case passwordOnly
  case defaultUser

  var username: String? {
    switch self {
    case .passwordOnly: nil
    case .defaultUser: "default"
    }
  }
}

private enum RedisIntegrationEnvironment {
  // These gates are deliberately enforced in test code, not only in workflow YAML.
  // `GITHUB_ACTIONS` proves that GitHub is executing the test process, while the
  // package-specific opt-in confines real-server access to the dedicated workflow.
  // This prevents `swift test`, Xcode, and unrelated CI jobs from probing a developer's
  // Redis instance or creating an expectation that Redis be installed on the local Mac.
  static var shouldRun: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["GITHUB_ACTIONS"] == "true"
      && environment["HIREDIS_RUN_REDIS_INTEGRATION"] == "1"
  }

  static func server() throws -> RedisServerSettings {
    let environment = ProcessInfo.processInfo.environment
    let hostname = try #require(
      environment["HIREDIS_REDIS_HOST"],
      "The Redis integration workflow must provide HIREDIS_REDIS_HOST."
    )
    let portText = try #require(
      environment["HIREDIS_REDIS_PORT"],
      "The Redis integration workflow must provide HIREDIS_REDIS_PORT."
    )
    let port = try #require(
      Int(portText),
      "HIREDIS_REDIS_PORT must contain a decimal TCP port."
    )
    let password = try #require(
      environment["HIREDIS_REDIS_PASSWORD"],
      "The Redis integration workflow must provide HIREDIS_REDIS_PASSWORD."
    )
    return RedisServerSettings(hostname: hostname, port: port, password: password)
  }
}

private struct RedisServerSettings: Sendable {
  let hostname: String
  let port: Int
  let password: String
}
