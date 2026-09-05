import Foundation

#if os(Linux)
import FoundationNetworking

/// FoundationNetworking does not currently provide URLSession's streaming API.
/// This compatibility implementation preserves the API used by the package so
/// command-line builds can consume complete HTTP responses on Linux.
public struct URLSessionAsyncBytes: AsyncSequence, @unchecked Sendable {
  public typealias Element = UInt8

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var iterator: Data.Iterator

    fileprivate init(_ data: Data) {
      iterator = data.makeIterator()
    }

    public mutating func next() async throws -> UInt8? {
      iterator.next()
    }
  }

  private let data: Data

  public init(_ data: Data) {
    self.data = data
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(data)
  }

  public var task: URLSessionTask? { nil }

  public var lines: AsyncThrowingStream<String, Error> {
    let lines = String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        line.last == "\r" ? String(line.dropLast()) : String(line)
      }
    return AsyncThrowingStream { continuation in
      for line in lines {
        continuation.yield(line)
      }
      continuation.finish()
    }
  }
}

public extension URLSession {
  typealias AsyncBytes = URLSessionAsyncBytes

  func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
    let (data, response) = try await data(for: request)
    return (AsyncBytes(data), response)
  }

  func bytes(
    for request: URLRequest,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (AsyncBytes, URLResponse) {
    let (data, response) = try await data(for: request, delegate: delegate)
    return (AsyncBytes(data), response)
  }
}
#endif
