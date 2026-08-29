import Foundation
import Testing

@testable import Hiredis

@Suite("Connection configuration")
struct ConfigurationTests {
  @Test("Valid configuration preserves public values")
  func validConfiguration() throws {
    let configuration = try HiredisConfiguration(
      hostname: "cache.example.test",
      port: 6_380,
      username: "application",
      password: "credential",
      database: 4,
      connectionTimeout: .milliseconds(750),
      commandTimeout: .seconds(2),
      protocolVersion: .resp3
    )

    #expect(configuration.hostname == "cache.example.test")
    #expect(configuration.port == 6_380)
    #expect(configuration.database == 4)
    #expect(configuration.protocolVersion == .resp3)
    #expect(configuration.connectionTimeoutMicroseconds == 750_000)
    #expect(configuration.commandTimeoutMicroseconds == 2_000_000)
  }

  @Test("Rejects an empty hostname")
  func emptyHostname() {
    #expect(throws: HiredisError.configuration(.emptyHostname)) {
      try HiredisConfiguration(hostname: "")
    }
  }

  @Test("Rejects a hostname containing a C null byte")
  func nullInHostname() {
    #expect(throws: HiredisError.configuration(.hostnameContainsNullByte)) {
      try HiredisConfiguration(hostname: "local\0host")
    }
  }

  @Test("Rejects ports outside the TCP range", arguments: [-1, 0, 65_536])
  func invalidPorts(_ port: Int) {
    #expect(throws: HiredisError.configuration(.invalidPort(port))) {
      try HiredisConfiguration(hostname: "localhost", port: port)
    }
  }

  @Test("Rejects a negative database")
  func negativeDatabase() {
    #expect(throws: HiredisError.configuration(.invalidDatabase(-1))) {
      try HiredisConfiguration(hostname: "localhost", database: -1)
    }
  }

  @Test("Rejects a username without a password")
  func usernameWithoutPassword() {
    #expect(throws: HiredisError.configuration(.usernameRequiresPassword)) {
      try HiredisConfiguration(hostname: "localhost", username: "default")
    }
  }

  @Test("Rejects non-positive and sub-microsecond timeouts")
  func invalidTimeouts() {
    #expect(throws: HiredisError.configuration(.invalidConnectionTimeout)) {
      try HiredisConfiguration(hostname: "localhost", connectionTimeout: .zero)
    }
    #expect(throws: HiredisError.configuration(.invalidCommandTimeout)) {
      try HiredisConfiguration(
        hostname: "localhost",
        commandTimeout: .nanoseconds(500)
      )
    }
  }

  @Test("Descriptions redact authentication values")
  func safeDescription() throws {
    let username = "private-user"
    let password = "private-password"
    let configuration = try HiredisConfiguration(
      hostname: "localhost",
      username: username,
      password: password
    )

    let descriptions = [configuration.description, configuration.debugDescription]
    for description in descriptions {
      #expect(!description.contains(username))
      #expect(!description.contains(password))
      #expect(description.contains("<redacted>"))
    }
  }

  @Test("TLS is represented but explicitly unavailable")
  func tlsIsDeferred() async throws {
    let configuration = try HiredisConfiguration(
      hostname: "localhost",
      transportSecurity: .tls
    )
    let connection = HiredisConnection(configuration: configuration)

    do {
      try await connection.connect()
      Issue.record("TLS connection unexpectedly succeeded")
    } catch let error as HiredisError {
      #expect(error == .configuration(.tlsUnavailable))
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }
}
