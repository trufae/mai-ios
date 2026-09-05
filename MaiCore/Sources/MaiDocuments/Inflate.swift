import Foundation

/// A small RFC 1951 (deflate) decoder used where Apple's Compression framework
/// is unavailable, for example when the CLI runs on Linux. It follows the
/// structure of zlib's reference `puff.c`: bit-serial canonical Huffman
/// decoding, which is slow but simple and easy to verify.
enum Inflate {
  enum Failure: Error, Equatable {
    case truncatedInput
    case invalidBlockType
    case invalidStoredBlock
    case invalidCodeLengths
    case invalidSymbol
    case invalidDistance
    case outputTooLarge
  }

  /// Decompressed output is capped so a hostile archive cannot exhaust memory.
  static let maximumOutputBytes = 256 * 1024 * 1024

  static func decompress(_ input: Data, expectedSize: Int? = nil) throws -> Data {
    var state = State(input: [UInt8](input), expectedSize: expectedSize)
    try state.run()
    return Data(state.output)
  }

  private struct Huffman {
    /// `counts[n]` is the number of codes with length `n`; index 0 is unused.
    var counts: [Int]
    /// Symbols ordered by code length, then by value.
    var symbols: [Int]
  }

  private static let lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
  ]
  private static let lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  private static let distanceBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
  ]
  /// Order in which code-length code lengths are stored in a dynamic block.
  private static let codeLengthOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  ]

  private static let fixedLiteralCodes: Huffman = {
    var lengths = [Int](repeating: 8, count: 288)
    for symbol in 144..<256 { lengths[symbol] = 9 }
    for symbol in 256..<280 { lengths[symbol] = 7 }
    // The fixed table is complete by construction, so this cannot throw.
    return (try? construct(lengths)) ?? Huffman(counts: [], symbols: [])
  }()

  private static let fixedDistanceCodes: Huffman = {
    (try? construct([Int](repeating: 5, count: 30))) ?? Huffman(counts: [], symbols: [])
  }()

  private static func construct(_ lengths: [Int]) throws -> Huffman {
    var counts = [Int](repeating: 0, count: 16)
    for length in lengths {
      guard (0...15).contains(length) else { throw Failure.invalidCodeLengths }
      counts[length] += 1
    }
    var remaining = 1
    for length in 1...15 {
      remaining <<= 1
      remaining -= counts[length]
      guard remaining >= 0 else { throw Failure.invalidCodeLengths }
    }
    var offsets = [Int](repeating: 0, count: 16)
    for length in 1..<15 {
      offsets[length + 1] = offsets[length] + counts[length]
    }
    var symbols = [Int](repeating: 0, count: lengths.count)
    for (symbol, length) in lengths.enumerated() where length != 0 {
      symbols[offsets[length]] = symbol
      offsets[length] += 1
    }
    return Huffman(counts: counts, symbols: symbols)
  }

  private struct State {
    let input: [UInt8]
    var position = 0
    var bitBuffer = 0
    var bitCount = 0
    var output: [UInt8] = []

    init(input: [UInt8], expectedSize: Int?) {
      self.input = input
      output.reserveCapacity(min(expectedSize ?? input.count * 4, Inflate.maximumOutputBytes))
    }

    mutating func run() throws {
      var isFinal = false
      repeat {
        isFinal = try bits(1) == 1
        switch try bits(2) {
        case 0: try storedBlock()
        case 1:
          try codes(literals: Inflate.fixedLiteralCodes, distances: Inflate.fixedDistanceCodes)
        case 2: try dynamicBlock()
        default: throw Failure.invalidBlockType
        }
      } while !isFinal
    }

    private mutating func bits(_ count: Int) throws -> Int {
      var value = bitBuffer
      while bitCount < count {
        guard position < input.count else { throw Failure.truncatedInput }
        value |= Int(input[position]) << bitCount
        position += 1
        bitCount += 8
      }
      bitBuffer = value >> count
      bitCount -= count
      return value & ((1 << count) - 1)
    }

    private mutating func storedBlock() throws {
      // Stored blocks start on a byte boundary; the leftover bits are padding.
      bitBuffer = 0
      bitCount = 0
      guard position + 4 <= input.count else { throw Failure.truncatedInput }
      let length = Int(input[position]) | Int(input[position + 1]) << 8
      let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
      guard length == (~complement & 0xFFFF) else { throw Failure.invalidStoredBlock }
      position += 4
      guard position + length <= input.count else { throw Failure.truncatedInput }
      try append(input[position..<position + length])
      position += length
    }

    private mutating func decode(_ table: Huffman) throws -> Int {
      var code = 0
      var first = 0
      var index = 0
      for length in 1...15 {
        code |= try bits(1)
        let count = table.counts[length]
        if code - count < first {
          return table.symbols[index + (code - first)]
        }
        index += count
        first += count
        first <<= 1
        code <<= 1
      }
      throw Failure.invalidSymbol
    }

    private mutating func codes(literals: Huffman, distances: Huffman) throws {
      while true {
        let symbol = try decode(literals)
        if symbol < 256 {
          try append(CollectionOfOne(UInt8(symbol)))
        } else if symbol == 256 {
          return
        } else {
          let lengthIndex = symbol - 257
          guard lengthIndex < Inflate.lengthBase.count else { throw Failure.invalidSymbol }
          let length =
            Inflate.lengthBase[lengthIndex] + (try bits(Inflate.lengthExtra[lengthIndex]))
          let distanceIndex = try decode(distances)
          guard distanceIndex < Inflate.distanceBase.count else { throw Failure.invalidDistance }
          let distance =
            Inflate.distanceBase[distanceIndex] + (try bits(Inflate.distanceExtra[distanceIndex]))
          guard distance <= output.count else { throw Failure.invalidDistance }
          guard output.count + length <= Inflate.maximumOutputBytes else {
            throw Failure.outputTooLarge
          }
          // Copies may overlap their own output, so they go byte by byte.
          for _ in 0..<length {
            output.append(output[output.count - distance])
          }
        }
      }
    }

    private mutating func dynamicBlock() throws {
      let literalCount = try bits(5) + 257
      let distanceCount = try bits(5) + 1
      let codeLengthCount = try bits(4) + 4
      guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalidCodeLengths }

      var codeLengths = [Int](repeating: 0, count: 19)
      for index in 0..<codeLengthCount {
        codeLengths[Inflate.codeLengthOrder[index]] = try bits(3)
      }
      let codeLengthCodes = try Inflate.construct(codeLengths)

      var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
      var index = 0
      while index < lengths.count {
        let symbol = try decode(codeLengthCodes)
        if symbol < 16 {
          lengths[index] = symbol
          index += 1
          continue
        }
        var repeated = 0
        var count: Int
        switch symbol {
        case 16:
          guard index > 0 else { throw Failure.invalidCodeLengths }
          repeated = lengths[index - 1]
          count = 3 + (try bits(2))
        case 17:
          count = 3 + (try bits(3))
        default:
          count = 11 + (try bits(7))
        }
        guard index + count <= lengths.count else { throw Failure.invalidCodeLengths }
        for _ in 0..<count {
          lengths[index] = repeated
          index += 1
        }
      }
      guard lengths[256] != 0 else { throw Failure.invalidCodeLengths }

      let literals = try Inflate.construct(Array(lengths[0..<literalCount]))
      let distances = try Inflate.construct(Array(lengths[literalCount...]))
      try codes(literals: literals, distances: distances)
    }

    private mutating func append<Bytes: Collection>(_ bytes: Bytes) throws
    where Bytes.Element == UInt8 {
      guard output.count + bytes.count <= Inflate.maximumOutputBytes else {
        throw Failure.outputTooLarge
      }
      output.append(contentsOf: bytes)
    }
  }
}
