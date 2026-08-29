import Foundation

public enum HiredisConfigurationIssue: Sendable, Equatable {
  case emptyHostname
  case hostnameContainsNullByte
  case invalidPort(Int)
  case invalidDatabase(Int)
  case invalidConnectionTimeout
  case invalidCommandTimeout
  case usernameRequiresPassword
  case tlsUnavailable
  case emptyCommand
  case tooManyCommandArguments
}

public enum HiredisOperation: String, Sendable, Equatable {
  case connect
  case command
}

public enum HiredisLifetimeIssue: Sendable, Equatable {
  case alreadyConnected
  case notConnected
  case missingReply
  case incompleteReply
  case invalidReplyStorage
}

public struct HiredisServerError: Error, Sendable, Equatable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  init(rawMessage: String) {
    let parts = rawMessage.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    code = parts.first.map(String.init) ?? "ERR"
    message = parts.count == 2 ? String(parts[1]) : ""
  }

  var rawMessage: String {
    message.isEmpty ? code : "\(code) \(message)"
  }
}

public enum HiredisError: Error, Sendable, Equatable {
  case configuration(HiredisConfigurationIssue)
  case connection(operation: HiredisOperation, message: String)
  case timeout(HiredisOperation)
  case protocolFailure(message: String)
  case serverReply(HiredisServerError)
  case cancellation
  case invalidLifetime(HiredisLifetimeIssue)
  case resource(message: String)
}

extension HiredisError: LocalizedError, CustomStringConvertible {
  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .configuration(let issue):
      "Invalid hiredis configuration: \(issue.description)"
    case .connection(let operation, let message):
      "Hiredis \(operation.rawValue) failed: \(message)"
    case .timeout(let operation):
      "Hiredis \(operation.rawValue) timed out"
    case .protocolFailure(let message):
      "Hiredis protocol failure: \(message)"
    case .serverReply(let error):
      "Redis server error: \(error.rawMessage)"
    case .cancellation:
      "Hiredis operation was cancelled"
    case .invalidLifetime(let issue):
      "Invalid hiredis connection lifetime: \(issue.description)"
    case .resource(let message):
      "Hiredis resource failure: \(message)"
    }
  }
}

extension HiredisConfigurationIssue: CustomStringConvertible {
  public var description: String {
    switch self {
    case .emptyHostname: "hostname must not be empty"
    case .hostnameContainsNullByte: "hostname must not contain a null byte"
    case .invalidPort(let port): "port \(port) is outside 1...65535"
    case .invalidDatabase(let database): "database \(database) must not be negative"
    case .invalidConnectionTimeout: "connection timeout must be at least one microsecond"
    case .invalidCommandTimeout: "command timeout must be at least one microsecond"
    case .usernameRequiresPassword: "a username requires a password"
    case .tlsUnavailable: "TLS is not available in hiredis-swift 0.1"
    case .emptyCommand: "a command must contain at least one argument"
    case .tooManyCommandArguments: "the command has more arguments than hiredis supports"
    }
  }
}

extension HiredisLifetimeIssue: CustomStringConvertible {
  public var description: String {
    switch self {
    case .alreadyConnected: "connect was called while the connection was already open"
    case .notConnected: "the connection is closed"
    case .missingReply: "hiredis completed without returning a reply"
    case .incompleteReply: "the byte fixture did not contain one complete reply"
    case .invalidReplyStorage: "hiredis returned inconsistent reply storage"
    }
  }
}

struct CredentialRedactor: Sendable {
  private let secrets: [String]

  init(secrets: [String]) {
    self.secrets = Array(Set(secrets.filter { !$0.isEmpty }))
      .sorted { $0.count > $1.count }
  }

  func adding(argumentsFromAuthenticationCommand arguments: [Data]) -> Self {
    guard let command = arguments.first.flatMap({ String(data: $0, encoding: .utf8) }),
      !arguments.isEmpty
    else { return self }

    let authenticationArguments: ArraySlice<Data>
    if command.caseInsensitiveCompare("AUTH") == .orderedSame {
      authenticationArguments = arguments.dropFirst()
    } else if command.caseInsensitiveCompare("HELLO") == .orderedSame,
      let authenticationIndex = arguments.firstIndex(where: { argument in
        String(data: argument, encoding: .utf8)?
          .caseInsensitiveCompare("AUTH") == .orderedSame
      })
    {
      let start = arguments.index(after: authenticationIndex)
      let end =
        arguments.index(start, offsetBy: 2, limitedBy: arguments.endIndex)
        ?? arguments.endIndex
      authenticationArguments = arguments[start..<end]
    } else {
      return self
    }

    let argumentSecrets = authenticationArguments.compactMap {
      String(data: $0, encoding: .utf8)
    }
    return Self(secrets: secrets + argumentSecrets)
  }

  func redact(_ value: String) -> String {
    secrets.reduce(value) { partial, secret in
      partial.replacingOccurrences(of: secret, with: "<redacted>")
    }
  }

  func redact(_ error: HiredisServerError) -> HiredisServerError {
    HiredisServerError(
      code: redact(error.code),
      message: redact(error.message)
    )
  }
}
