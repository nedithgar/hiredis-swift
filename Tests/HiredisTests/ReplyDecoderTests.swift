import Foundation
import Testing

@testable import Hiredis

@Suite("RESP reply conversion")
struct ReplyDecoderTests {
  @Test(
    "Parses every scalar hiredis reply kind",
    arguments: [
      (Data("$5\r\nhello\r\n".utf8), HiredisReply.bulkString(Data("hello".utf8))),
      (Data(":-42\r\n".utf8), .integer(-42)),
      (Data("$-1\r\n".utf8), .null),
      (Data("*-1\r\n".utf8), .null),
      (Data("+OK\r\n".utf8), .status("OK")),
      (
        Data("-WRONGTYPE incompatible value\r\n".utf8),
        .error(HiredisServerError(code: "WRONGTYPE", message: "incompatible value"))
      ),
      (Data(",1.25\r\n".utf8), .double(1.25)),
      (Data("#t\r\n".utf8), .boolean(true)),
      (Data("#f\r\n".utf8), .boolean(false)),
      (
        Data("(3492890328409238509324850943850943825024385\r\n".utf8),
        .bigNumber("3492890328409238509324850943850943825024385")
      ),
      (
        Data("=15\r\ntxt:hello world\r\n".utf8),
        .verbatim(HiredisVerbatimString(format: "txt", data: Data("hello world".utf8)))
      ),
      (Data("_\r\n".utf8), .null),
    ]
  )
  func scalarReplies(_ fixture: Data, _ expected: HiredisReply) throws {
    #expect(try HiredisReplyDecoder.decode(fixture) == expected)
  }

  @Test("Preserves embedded null bytes in bulk strings")
  func binaryBulkString() throws {
    var fixture = Data("$5\r\n".utf8)
    fixture.append(contentsOf: [0x61, 0x00, 0x62, 0x00, 0x63])
    fixture.append(Data("\r\n".utf8))

    #expect(
      try HiredisReplyDecoder.decode(fixture)
        == .bulkString(Data([0x61, 0x00, 0x62, 0x00, 0x63]))
    )
  }

  @Test("Parses RESP2 arrays")
  func array() throws {
    let fixture = Data("*3\r\n+first\r\n:2\r\n$5\r\nthird\r\n".utf8)
    #expect(
      try HiredisReplyDecoder.decode(fixture)
        == .array([
          .status("first"),
          .integer(2),
          .bulkString(Data("third".utf8)),
        ])
    )
  }

  @Test("Parses RESP3 maps")
  func map() throws {
    let fixture = Data("%2\r\n+first\r\n:1\r\n+second\r\n#t\r\n".utf8)
    #expect(
      try HiredisReplyDecoder.decode(fixture)
        == .map([
          HiredisMapEntry(key: .status("first"), value: .integer(1)),
          HiredisMapEntry(key: .status("second"), value: .boolean(true)),
        ])
    )
  }

  @Test("Parses RESP3 sets")
  func set() throws {
    let fixture = Data("~2\r\n+one\r\n+two\r\n".utf8)
    #expect(
      try HiredisReplyDecoder.decode(fixture) == .set([.status("one"), .status("two")])
    )
  }

  @Test("Parses RESP3 attributes")
  func attribute() throws {
    let fixture = Data("|1\r\n+ttl\r\n:30\r\n".utf8)
    #expect(
      try HiredisReplyDecoder.decode(fixture)
        == .attribute([
          HiredisMapEntry(key: .status("ttl"), value: .integer(30))
        ])
    )
  }

  @Test("Parses RESP3 push messages")
  func push() throws {
    let fixture = Data(">2\r\n+message\r\n$5\r\nhello\r\n".utf8)
    #expect(
      try HiredisReplyDecoder.decode(fixture)
        == .push([
          .status("message"),
          .bulkString(Data("hello".utf8)),
        ])
    )
  }

  @Test("Rejects RESP3 blob errors unsupported by hiredis 1.4.1")
  func unsupportedBlobError() {
    let fixture = Data("!21\r\nSYNTAX invalid syntax\r\n".utf8)
    #expect(throws: HiredisError.self) {
      try HiredisReplyDecoder.decode(fixture)
    }
  }

  @Test("Parses all special RESP3 double values")
  func specialDoubles() throws {
    let positive = try HiredisReplyDecoder.decode(Data(",inf\r\n".utf8))
    let negative = try HiredisReplyDecoder.decode(Data(",-inf\r\n".utf8))
    let nan = try HiredisReplyDecoder.decode(Data(",nan\r\n".utf8))

    #expect(positive == .double(.infinity))
    #expect(negative == .double(-.infinity))
    guard case .double(let nanValue) = nan else {
      Issue.record("Expected a RESP3 double")
      return
    }
    #expect(nanValue.isNaN)
  }

  @Test("Reports malformed and incomplete protocol input")
  func invalidInput() {
    do {
      _ = try HiredisReplyDecoder.decode(Data("?invalid\r\n".utf8))
      Issue.record("Malformed RESP unexpectedly parsed")
    } catch let error as HiredisError {
      guard case .protocolFailure = error else {
        Issue.record("Expected a protocol failure, got \(error)")
        return
      }
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }

    #expect(throws: HiredisError.invalidLifetime(.incompleteReply)) {
      try HiredisReplyDecoder.decode(Data("$5\r\nabc".utf8))
    }
  }

  @Test("Replies remain valid after C storage is repeatedly freed")
  func repeatedOwnershipCleanup() throws {
    let fixture = Data("*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n".utf8)
    let expected = HiredisReply.array([
      .bulkString(Data("hello".utf8)),
      .bulkString(Data("world".utf8)),
    ])

    var retainedReplies: [HiredisReply] = []
    retainedReplies.reserveCapacity(2_000)
    for _ in 0..<2_000 {
      retainedReplies.append(try HiredisReplyDecoder.decode(fixture))
    }

    #expect(retainedReplies.first == expected)
    #expect(retainedReplies.last == expected)
  }
}
