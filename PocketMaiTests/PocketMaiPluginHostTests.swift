import XCTest

@testable import PocketMai

final class PocketMaiPluginHostTests: XCTestCase {
  func testStaticPluginsProvideOpenAIAndOCRFactories() async throws {
    let plugins = try await PocketMaiPluginHost.shared.installedPlugins()
    XCTAssertEqual(
      Set(plugins.map(\.manifest.id.rawValue)),
      ["org.mai.openai", "org.mai.pocketmai-platform", "org.mai.standard-tools"])

    let endpointID = UUID()
    let provider = try await PocketMaiPluginHost.shared.makeOpenAIProvider(
      endpoint: OpenAIEndpoint(
        id: endpointID,
        name: "Fixture",
        baseURL: "https://example.com/v1",
        apiKey: "test"))
    XCTAssertEqual(provider.descriptor.id.rawValue, endpointID.uuidString)
    XCTAssertEqual(provider.descriptor.displayName, "Fixture")

    let ocr = try await PocketMaiPluginHost.shared.makeOCRProvider()
    XCTAssertEqual(ocr.descriptor.id, "pocketmai-vision")
  }
}
