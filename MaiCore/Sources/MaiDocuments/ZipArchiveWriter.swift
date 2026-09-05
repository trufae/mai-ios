import Foundation

/// Writes a stored (uncompressed) zip archive. WebXDC bundles and exported
/// document packages only need the container, not compression.
public enum ZipArchiveWriter {
  public static func write(entries: [(path: String, data: Data)], to url: URL) throws {
    try archive(entries: entries).write(to: url, options: [.atomic])
  }

  public static func archive(entries: [(path: String, data: Data)]) -> Data {
    var output = Data()
    var central = Data()
    var records: [(name: Data, size: UInt32, offset: UInt32, crc: UInt32)] = []

    for entry in entries {
      guard let name = entry.path.data(using: .utf8) else { continue }
      let crc = crc32(entry.data)
      let size = UInt32(entry.data.count)
      records.append((name, size, UInt32(output.count), crc))
      output.appendUInt32(0x0403_4b50)
      output.appendUInt16(20)  // version needed
      output.appendUInt16(0)  // flags
      output.appendUInt16(0)  // method: store
      output.appendUInt16(0)  // mod time
      output.appendUInt16(0)  // mod date
      output.appendUInt32(crc)
      output.appendUInt32(size)
      output.appendUInt32(size)
      output.appendUInt16(UInt16(name.count))
      output.appendUInt16(0)  // extra length
      output.append(name)
      output.append(entry.data)
    }

    for record in records {
      central.appendUInt32(0x0201_4b50)
      central.appendUInt16(20)  // version made by
      central.appendUInt16(20)  // version needed
      central.appendUInt16(0)  // flags
      central.appendUInt16(0)  // method
      central.appendUInt16(0)  // mod time
      central.appendUInt16(0)  // mod date
      central.appendUInt32(record.crc)
      central.appendUInt32(record.size)
      central.appendUInt32(record.size)
      central.appendUInt16(UInt16(record.name.count))
      central.appendUInt16(0)  // extra
      central.appendUInt16(0)  // comment
      central.appendUInt16(0)  // disk
      central.appendUInt16(0)  // internal attrs
      central.appendUInt32(0)  // external attrs
      central.appendUInt32(record.offset)
      central.append(record.name)
    }

    let centralOffset = UInt32(output.count)
    output.append(central)
    output.appendUInt32(0x0605_4b50)
    output.appendUInt16(0)  // disk
    output.appendUInt16(0)  // central dir disk
    output.appendUInt16(UInt16(records.count))
    output.appendUInt16(UInt16(records.count))
    output.appendUInt32(UInt32(central.count))
    output.appendUInt32(centralOffset)
    output.appendUInt16(0)  // comment length
    return output
  }

  private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
    }
    return value
  }

  public static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}

extension Data {
  fileprivate mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8(value >> 8))
  }

  fileprivate mutating func appendUInt32(_ value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }
}
