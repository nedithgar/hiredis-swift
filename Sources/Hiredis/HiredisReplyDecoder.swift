import CHiredis
import Foundation

enum HiredisReplyDecoder {
  private static let maximumDepth = 128

  static func decode(_ bytes: Data) throws -> HiredisReply {
    guard let reader = redisReaderCreate() else {
      throw HiredisError.resource(message: "unable to allocate a RESP reader")
    }
    defer { redisReaderFree(reader) }

    let feedResult = bytes.withUnsafeBytes { buffer in
      redisReaderFeed(
        reader,
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        buffer.count
      )
    }
    guard feedResult == REDIS_OK else {
      throw readerError(reader)
    }

    var rawReply: UnsafeMutableRawPointer?
    guard redisReaderGetReply(reader, &rawReply) == REDIS_OK else {
      throw readerError(reader)
    }
    guard let rawReply else {
      throw HiredisError.invalidLifetime(.incompleteReply)
    }
    defer { freeReplyObject(rawReply) }

    return try copy(rawReply)
  }

  static func copy(_ rawReply: UnsafeRawPointer) throws -> HiredisReply {
    try copy(rawReply, depth: 0)
  }

  private static func copy(
    _ rawReply: UnsafeRawPointer,
    depth: Int
  ) throws -> HiredisReply {
    guard depth <= maximumDepth else {
      throw HiredisError.protocolFailure(
        message: "reply nesting exceeds \(maximumDepth) levels"
      )
    }

    switch chiredisReplyType(rawReply) {
    case REDIS_REPLY_STRING:
      return .bulkString(try data(from: rawReply))
    case REDIS_REPLY_ARRAY:
      return .array(try elements(from: rawReply, depth: depth))
    case REDIS_REPLY_INTEGER:
      return .integer(Int64(chiredisReplyInteger(rawReply)))
    case REDIS_REPLY_NIL:
      return .null
    case REDIS_REPLY_STATUS:
      return .status(try text(from: rawReply, kind: "status"))
    case REDIS_REPLY_ERROR:
      return .error(HiredisServerError(rawMessage: try text(from: rawReply, kind: "error")))
    case REDIS_REPLY_DOUBLE:
      return .double(chiredisReplyDouble(rawReply))
    case REDIS_REPLY_BOOL:
      return .boolean(chiredisReplyInteger(rawReply) != 0)
    case REDIS_REPLY_MAP:
      return .map(try mapEntries(from: rawReply, depth: depth))
    case REDIS_REPLY_SET:
      return .set(try elements(from: rawReply, depth: depth))
    case REDIS_REPLY_ATTR:
      return .attribute(try mapEntries(from: rawReply, depth: depth))
    case REDIS_REPLY_PUSH:
      return .push(try elements(from: rawReply, depth: depth))
    case REDIS_REPLY_BIGNUM:
      return .bigNumber(try text(from: rawReply, kind: "big number"))
    case REDIS_REPLY_VERB:
      guard let formatPointer = chiredisReplyVerbatimType(rawReply) else {
        throw HiredisError.invalidLifetime(.invalidReplyStorage)
      }
      let format = String(cString: formatPointer)
      guard format.utf8.count == 3 else {
        throw HiredisError.protocolFailure(
          message: "invalid RESP3 verbatim format identifier"
        )
      }
      return .verbatim(
        HiredisVerbatimString(format: format, data: try data(from: rawReply))
      )
    default:
      throw HiredisError.protocolFailure(
        message: "unsupported hiredis reply type \(chiredisReplyType(rawReply))"
      )
    }
  }

  private static func data(from rawReply: UnsafeRawPointer) throws -> Data {
    let count = chiredisReplyLength(rawReply)
    guard count > 0 else { return Data() }
    guard let bytes = chiredisReplyBytes(rawReply) else {
      throw HiredisError.invalidLifetime(.invalidReplyStorage)
    }
    return Data(bytes: bytes, count: count)
  }

  private static func text(
    from rawReply: UnsafeRawPointer,
    kind: String
  ) throws -> String {
    let value = try data(from: rawReply)
    guard let text = String(data: value, encoding: .utf8) else {
      throw HiredisError.protocolFailure(message: "RESP \(kind) is not valid UTF-8")
    }
    return text
  }

  private static func elements(
    from rawReply: UnsafeRawPointer,
    depth: Int
  ) throws -> [HiredisReply] {
    let rawCount = chiredisReplyElementCount(rawReply)
    guard let count = Int(exactly: rawCount) else {
      throw HiredisError.resource(message: "reply element count exceeds Swift limits")
    }

    var values: [HiredisReply] = []
    values.reserveCapacity(count)
    for index in 0..<count {
      guard let child = chiredisReplyElement(rawReply, index) else {
        throw HiredisError.invalidLifetime(.invalidReplyStorage)
      }
      values.append(try copy(child, depth: depth + 1))
    }
    return values
  }

  private static func mapEntries(
    from rawReply: UnsafeRawPointer,
    depth: Int
  ) throws -> [HiredisMapEntry] {
    let values = try elements(from: rawReply, depth: depth)
    guard values.count.isMultiple(of: 2) else {
      throw HiredisError.protocolFailure(message: "RESP3 map has an odd element count")
    }

    return stride(from: 0, to: values.count, by: 2).map { index in
      HiredisMapEntry(key: values[index], value: values[index + 1])
    }
  }

  private static func readerError(_ reader: UnsafeMutablePointer<redisReader>) -> HiredisError {
    let message = withUnsafePointer(to: reader.pointee.errstr) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 128) {
        String(cString: $0)
      }
    }
    return .protocolFailure(message: message.isEmpty ? "invalid RESP input" : message)
  }
}
