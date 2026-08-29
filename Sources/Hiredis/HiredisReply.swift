import Foundation

public struct HiredisMapEntry: Sendable, Equatable {
  public let key: HiredisReply
  public let value: HiredisReply

  public init(key: HiredisReply, value: HiredisReply) {
    self.key = key
    self.value = value
  }
}

public struct HiredisVerbatimString: Sendable, Equatable {
  public let format: String
  public let data: Data

  public init(format: String, data: Data) {
    self.format = format
    self.data = data
  }
}

/// An immutable, ownership-independent copy of a hiredis reply.
public indirect enum HiredisReply: Sendable, Equatable {
  case bulkString(Data)
  case array([HiredisReply])
  case integer(Int64)
  case null
  case status(String)
  case error(HiredisServerError)
  case double(Double)
  case boolean(Bool)
  case map([HiredisMapEntry])
  case set([HiredisReply])
  case attribute([HiredisMapEntry])
  case push([HiredisReply])
  case bigNumber(String)
  case verbatim(HiredisVerbatimString)
}

/// One command reply plus any out-of-band RESP3 metadata observed before it.
public struct HiredisCommandResponse: Sendable, Equatable {
  public let reply: HiredisReply
  public let attributes: [HiredisMapEntry]
  public let pushMessages: [[HiredisReply]]

  public init(
    reply: HiredisReply,
    attributes: [HiredisMapEntry] = [],
    pushMessages: [[HiredisReply]] = []
  ) {
    self.reply = reply
    self.attributes = attributes
    self.pushMessages = pushMessages
  }
}
