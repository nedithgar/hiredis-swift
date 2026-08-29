import Foundation

/// The Redis serialization protocol negotiated after connecting.
public enum HiredisProtocolVersion: Int, Sendable, Equatable, CaseIterable {
  case resp2 = 2
  case resp3 = 3
}

/// Transport security selection reserved for a future source-based TLS implementation.
public enum HiredisTransportSecurity: Sendable, Equatable {
  case plaintext
  case tls
}

/// Immutable settings for one hiredis connection.
public struct HiredisConfiguration: Sendable, Equatable {
  public let hostname: String
  public let port: Int
  public let username: String?
  public let password: String?
  public let database: Int
  public let connectionTimeout: Duration
  public let commandTimeout: Duration
  public let protocolVersion: HiredisProtocolVersion
  public let transportSecurity: HiredisTransportSecurity
  let connectionTimeoutMicroseconds: Int64
  let commandTimeoutMicroseconds: Int64

  public init(
    hostname: String,
    port: Int = 6379,
    username: String? = nil,
    password: String? = nil,
    database: Int = 0,
    connectionTimeout: Duration = .seconds(5),
    commandTimeout: Duration = .seconds(5),
    protocolVersion: HiredisProtocolVersion = .resp2,
    transportSecurity: HiredisTransportSecurity = .plaintext
  ) throws {
    guard !hostname.isEmpty else {
      throw HiredisError.configuration(.emptyHostname)
    }
    guard !hostname.utf8.contains(0) else {
      throw HiredisError.configuration(.hostnameContainsNullByte)
    }
    guard (1...65_535).contains(port) else {
      throw HiredisError.configuration(.invalidPort(port))
    }
    guard database >= 0 else {
      throw HiredisError.configuration(.invalidDatabase(database))
    }
    guard username == nil || password != nil else {
      throw HiredisError.configuration(.usernameRequiresPassword)
    }

    let connectionTimeoutMicroseconds = try Self.microseconds(
      from: connectionTimeout,
      invalidIssue: .invalidConnectionTimeout
    )
    let commandTimeoutMicroseconds = try Self.microseconds(
      from: commandTimeout,
      invalidIssue: .invalidCommandTimeout
    )

    self.hostname = hostname
    self.port = port
    self.username = username
    self.password = password
    self.database = database
    self.connectionTimeout = connectionTimeout
    self.commandTimeout = commandTimeout
    self.protocolVersion = protocolVersion
    self.transportSecurity = transportSecurity
    self.connectionTimeoutMicroseconds = connectionTimeoutMicroseconds
    self.commandTimeoutMicroseconds = commandTimeoutMicroseconds
  }
}

extension HiredisConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    let usernameState = username == nil ? "none" : "<configured>"
    let passwordState = password == nil ? "none" : "<redacted>"
    return "HiredisConfiguration(hostname: \(hostname), port: \(port), "
      + "username: \(usernameState), password: \(passwordState), database: \(database), "
      + "protocol: RESP\(protocolVersion.rawValue), security: \(transportSecurity))"
  }

  public var debugDescription: String { description }
}

extension HiredisConfiguration {
  var authenticationArguments: [Data]? {
    guard let password else { return nil }

    if let username {
      return [Data("AUTH".utf8), Data(username.utf8), Data(password.utf8)]
    }
    return [Data("AUTH".utf8), Data(password.utf8)]
  }

  var credentialStrings: [String] {
    [username, password].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
  }

  private static func microseconds(
    from duration: Duration,
    invalidIssue: HiredisConfigurationIssue
  ) throws -> Int64 {
    guard duration > .zero else {
      throw HiredisError.configuration(invalidIssue)
    }

    let components = duration.components
    let (wholeMicroseconds, secondsOverflow) =
      components.seconds.multipliedReportingOverflow(by: 1_000_000)
    let fractionalMicroseconds = components.attoseconds / 1_000_000_000_000
    let (totalMicroseconds, additionOverflow) =
      wholeMicroseconds.addingReportingOverflow(fractionalMicroseconds)

    guard !secondsOverflow, !additionOverflow, totalMicroseconds > 0 else {
      throw HiredisError.configuration(invalidIssue)
    }
    return totalMicroseconds
  }
}
