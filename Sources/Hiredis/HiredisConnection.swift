import CHiredis
import Foundation

/// A single serialized hiredis connection running on its own dispatch-backed executor.
public actor HiredisConnection {
  private nonisolated let executor: HiredisSerialExecutor
  private nonisolated let socketInterrupter = HiredisSocketInterrupter()
  private let configuration: HiredisConfiguration
  private let credentialRedactor: CredentialRedactor
  private let contextOwner = HiredisContextOwner()

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  public init(configuration: HiredisConfiguration) {
    self.configuration = configuration
    credentialRedactor = CredentialRedactor(secrets: configuration.credentialStrings)
    executor = HiredisSerialExecutor(label: "dev.hiredis-swift.connection")
  }

  public var isConnected: Bool {
    guard let context = contextOwner.pointer else { return false }
    return chiredisContextIsConnected(context) != 0
  }

  /// Opens the connection and applies authentication, RESP negotiation, and database selection.
  public func connect() async throws {
    try await performCancellableOperation { operation in
      try connectSynchronously(operation: operation)
    }
  }

  /// Closes the socket and releases its hiredis context. Calling this repeatedly is safe.
  public func close() {
    closeSynchronously()
  }

  /// Replaces the current context with a fresh connection and repeats the full handshake.
  public func reconnect() async throws {
    try await performCancellableOperation { operation in
      closeSynchronously()
      guard !socketInterrupter.isCancelled(operation) else {
        throw HiredisError.cancellation
      }
      try connectSynchronously(operation: operation)
    }
  }

  /// Sends `PING` and returns the server's text response.
  @discardableResult
  public func ping() async throws -> String {
    let response = try await command(arguments: [Data("PING".utf8)])
    switch response.reply {
    case .status(let value):
      return value
    case .bulkString(let value):
      guard let text = String(data: value, encoding: .utf8) else {
        throw HiredisError.protocolFailure(message: "PING returned non-UTF-8 data")
      }
      return text
    default:
      throw HiredisError.protocolFailure(
        message: "PING returned an unexpected reply type"
      )
    }
  }

  /// Executes one binary-safe command using hiredis' `argv` API.
  public func command(arguments: [Data]) async throws -> HiredisCommandResponse {
    try await performCancellableOperation { _ in
      try performCommand(arguments)
    }
  }

  private func performCancellableOperation<Result>(
    _ body: (HiredisSocketInterrupter.Operation) throws -> Result
  ) async throws -> Result {
    let operation = socketInterrupter.prepareOperation()
    return try await withTaskCancellationHandler {
      guard socketInterrupter.start(operation) else {
        _ = socketInterrupter.finish(operation)
        throw HiredisError.cancellation
      }

      let result: Result
      do {
        result = try body(operation)
      } catch {
        let wasCancelled = socketInterrupter.finish(operation)
        if wasCancelled {
          closeSynchronously()
          throw HiredisError.cancellation
        }
        throw error
      }

      let wasCancelled = socketInterrupter.finish(operation)
      if wasCancelled {
        closeSynchronously()
        throw HiredisError.cancellation
      }
      return result
    } onCancel: {
      socketInterrupter.interrupt(operation)
    }
  }

  private func connectSynchronously(
    operation: HiredisSocketInterrupter.Operation
  ) throws {
    guard contextOwner.pointer == nil else {
      throw HiredisError.invalidLifetime(.alreadyConnected)
    }
    guard configuration.transportSecurity == .plaintext else {
      throw HiredisError.configuration(.tlsUnavailable)
    }

    let newContext = configuration.hostname.withCString { hostname in
      chiredisConnect(
        hostname,
        CInt(configuration.port),
        configuration.connectionTimeoutMicroseconds,
        configuration.commandTimeoutMicroseconds
      )
    }
    guard let newContext else {
      throw HiredisError.resource(message: "unable to allocate a hiredis context")
    }

    contextOwner.install(newContext)
    let descriptor = chiredisContextFileDescriptor(newContext)
    if descriptor >= 0 {
      socketInterrupter.install(Int32(descriptor))
    }
    guard !socketInterrupter.isCancelled(operation) else {
      closeSynchronously()
      throw HiredisError.cancellation
    }

    guard chiredisContextIsConnected(newContext) != 0 else {
      let error = contextError(operation: .connect, context: newContext)
      closeSynchronously()
      throw error
    }

    do {
      if let authenticationArguments = configuration.authenticationArguments {
        _ = try performCommand(authenticationArguments)
      }
      if configuration.protocolVersion == .resp3 {
        _ = try performCommand([Data("HELLO".utf8), Data("3".utf8)])
      }
      if configuration.database != 0 {
        _ = try performCommand([
          Data("SELECT".utf8),
          Data(String(configuration.database).utf8),
        ])
      }
    } catch {
      closeSynchronously()
      throw error
    }
  }

  private func closeSynchronously() {
    guard contextOwner.pointer != nil else {
      socketInterrupter.clear()
      return
    }
    socketInterrupter.clear()
    contextOwner.release()
  }

  private func performCommand(_ arguments: [Data]) throws -> HiredisCommandResponse {
    guard !arguments.isEmpty else {
      throw HiredisError.configuration(.emptyCommand)
    }
    guard arguments.count <= Int(CInt.max) else {
      throw HiredisError.configuration(.tooManyCommandArguments)
    }
    guard let context = contextOwner.pointer else {
      throw HiredisError.invalidLifetime(.notConnected)
    }

    let appendResult = HiredisCommandArguments.withUnsafeArguments(arguments) {
      argumentPointers,
      lengths in
      redisAppendCommandArgv(
        context,
        CInt(arguments.count),
        argumentPointers,
        lengths
      )
    }
    guard appendResult == REDIS_OK else {
      throw contextFailure(operation: .command, context: context)
    }

    var attributes: [HiredisMapEntry] = []
    var pushMessages: [[HiredisReply]] = []
    let errorRedactor = credentialRedactor.adding(
      argumentsFromAuthenticationCommand: arguments
    )

    while true {
      var rawReply: UnsafeMutableRawPointer?
      guard redisGetReply(context, &rawReply) == REDIS_OK else {
        throw contextFailure(operation: .command, context: context)
      }
      guard let rawReply else {
        throw HiredisError.invalidLifetime(.missingReply)
      }
      defer { freeReplyObject(rawReply) }

      let reply = try HiredisReplyDecoder.copy(rawReply)
      switch reply {
      case .attribute(let entries):
        attributes.append(contentsOf: entries)
      case .push(let values):
        pushMessages.append(values)
      case .error(let serverError):
        throw HiredisError.serverReply(errorRedactor.redact(serverError))
      default:
        return HiredisCommandResponse(
          reply: reply,
          attributes: attributes,
          pushMessages: pushMessages
        )
      }
    }
  }

  private func contextFailure(
    operation: HiredisOperation,
    context: UnsafeMutablePointer<redisContext>
  ) -> HiredisError {
    let error = contextError(operation: operation, context: context)
    closeSynchronously()
    return error
  }

  private func contextError(
    operation: HiredisOperation,
    context: UnsafeMutablePointer<redisContext>
  ) -> HiredisError {
    let code = chiredisContextErrorCode(context)
    let timedOut = chiredisContextErrorIsTimeout(context) != 0
    let rawMessage =
      chiredisContextErrorString(context).map(String.init(cString:))
      ?? "unknown hiredis error"
    let message = credentialRedactor.redact(rawMessage)

    if timedOut {
      return .timeout(operation)
    }

    switch code {
    case REDIS_ERR_PROTOCOL:
      return .protocolFailure(message: message)
    case REDIS_ERR_OOM:
      return .resource(message: message)
    default:
      return .connection(operation: operation, message: message)
    }
  }
}

private final class HiredisContextOwner {
  private(set) var pointer: UnsafeMutablePointer<redisContext>?

  init() {}

  func install(_ pointer: UnsafeMutablePointer<redisContext>) {
    precondition(self.pointer == nil, "A hiredis context is already installed")
    self.pointer = pointer
  }

  func release() {
    guard let pointer else { return }
    self.pointer = nil
    redisFree(pointer)
  }

  deinit {
    release()
  }
}
