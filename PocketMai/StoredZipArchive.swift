import Foundation

struct StoredZipArchive {
  private struct Entry {
    var path: String
    var data: Data
    var crc32: UInt32
    var offset: UInt32
  }

  private var buffer = Data()
  private var entries: [Entry] = []

  mutating func addFile(path: String, data: Data) {
    guard let pathData = path.data(using: .utf8),
      data.count <= UInt32.max,
      buffer.count <= UInt32.max
    else {
      return
    }

    let crc = CRC32.checksum(data)
    let offset = UInt32(buffer.count)
    buffer.appendUInt32LE(0x0403_4b50)
    buffer.appendUInt16LE(20)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt32LE(crc)
    buffer.appendUInt32LE(UInt32(data.count))
    buffer.appendUInt32LE(UInt32(data.count))
    buffer.appendUInt16LE(UInt16(pathData.count))
    buffer.appendUInt16LE(0)
    buffer.append(pathData)
    buffer.append(data)

    entries.append(Entry(path: path, data: data, crc32: crc, offset: offset))
  }

  func data() -> Data {
    var output = buffer
    let centralDirectoryOffset = UInt32(output.count)

    for entry in entries {
      guard let pathData = entry.path.data(using: .utf8) else { continue }
      output.appendUInt32LE(0x0201_4b50)
      output.appendUInt16LE(20)
      output.appendUInt16LE(20)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt32LE(entry.crc32)
      output.appendUInt32LE(UInt32(entry.data.count))
      output.appendUInt32LE(UInt32(entry.data.count))
      output.appendUInt16LE(UInt16(pathData.count))
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt32LE(0)
      output.appendUInt32LE(entry.offset)
      output.append(pathData)
    }

    let centralDirectorySize = UInt32(output.count) - centralDirectoryOffset
    output.appendUInt32LE(0x0605_4b50)
    output.appendUInt16LE(0)
    output.appendUInt16LE(0)
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt32LE(centralDirectorySize)
    output.appendUInt32LE(centralDirectoryOffset)
    output.appendUInt16LE(0)
    return output
  }
}

private enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var crc = UInt32(index)
    for _ in 0..<8 {
      if crc & 1 == 1 {
        crc = (crc >> 1) ^ 0xedb8_8320
      } else {
        crc >>= 1
      }
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      let index = Int((crc ^ UInt32(byte)) & 0xff)
      crc = (crc >> 8) ^ table[index]
    }
    return crc ^ 0xffff_ffff
  }
}

extension Data {
  fileprivate mutating func appendUInt16LE(_ value: UInt16) {
    append(UInt8(value & 0x00ff))
    append(UInt8((value >> 8) & 0x00ff))
  }

  fileprivate mutating func appendUInt32LE(_ value: UInt32) {
    append(UInt8(value & 0x0000_00ff))
    append(UInt8((value >> 8) & 0x0000_00ff))
    append(UInt8((value >> 16) & 0x0000_00ff))
    append(UInt8((value >> 24) & 0x0000_00ff))
  }
}
