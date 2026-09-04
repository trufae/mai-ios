import Foundation
import ImageIO
import MaiCore
import Vision

/// On-device OCR backed by Apple's Vision framework.
public struct VisionOCRProvider: OCRProvider {
  public let descriptor = OCRProviderDescriptor(id: "vision", displayName: "Apple Vision OCR")

  public init() {}

  public func recognize(_ request: OCRRequest) async throws -> OCRResult {
    try await Task.detached(priority: .userInitiated) {
      let visionRequest = VNRecognizeTextRequest()
      visionRequest.recognitionLevel = .accurate
      visionRequest.usesLanguageCorrection = true
      do {
        try VNImageRequestHandler(data: request.imageData, options: [:]).perform([visionRequest])
      } catch {
        guard
          let source = CGImageSourceCreateWithData(request.imageData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
          throw OCRProviderError.recognitionFailed(error.localizedDescription)
        }
        do {
          try VNImageRequestHandler(cgImage: image, options: [:]).perform([visionRequest])
        } catch {
          throw OCRProviderError.recognitionFailed(error.localizedDescription)
        }
      }
      let observations = (visionRequest.results ?? []).sorted { lhs, rhs in
        let verticalTolerance = min(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5
        if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > verticalTolerance {
          return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
      }
      let lines = observations.compactMap { observation in
        observation.topCandidates(1).first?.string
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard !lines.isEmpty else { throw OCRProviderError.noText }
      return OCRResult(markdown: lines.joined(separator: "\n"))
    }.value
  }
}

public struct MaiVisionOCRPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.vision-ocr",
    displayName: "Mai Vision OCR",
    version: "1.0.0",
    capabilities: [.ocrProvider])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      ocrFactory: VisionConfiguredOCRProviderFactory(),
      from: manifest.id)
  }
}

public struct VisionConfiguredOCRProviderFactory: ConfiguredOCRProviderFactory {
  public let kind = "vision"

  public init() {}

  public func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    VisionOCRProvider()
  }
}
