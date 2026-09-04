import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImageAttachmentMode: String, Codable, CaseIterable, Sendable {
  case tiny
  case small
  case medium
  case big
  case full
  case ocr

  public var maxDimension: Int? {
    switch self {
    case .tiny: 100
    case .small: 320
    case .medium: 640
    case .big: 1_024
    case .full, .ocr: nil
    }
  }
}

public struct OCRProviderDescriptor: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public struct OCRRequest: Codable, Equatable, Sendable {
  public var imageData: Data
  public var mimeType: String
  public var filename: String

  public init(imageData: Data, mimeType: String, filename: String) {
    self.imageData = imageData
    self.mimeType = mimeType
    self.filename = filename
  }
}

public struct OCRResult: Codable, Equatable, Sendable {
  public var markdown: String

  public init(markdown: String) {
    self.markdown = markdown
  }
}

/// A model-provider-independent OCR boundary. Hosts can use Vision, a remote
/// OCR service, or their own layout-aware recognizer without changing imports.
public protocol OCRProvider: Sendable {
  var descriptor: OCRProviderDescriptor { get }
  func recognize(_ request: OCRRequest) async throws -> OCRResult
}

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

public enum ImageAttachmentImporter {
  /// Imports an image as provider-neutral message content. OCR mode produces a
  /// Markdown file part rather than attaching the source image.
  public static func content(
    data: Data,
    mimeType: String,
    filename: String,
    mode: ImageAttachmentMode,
    ocrProvider: (any OCRProvider)? = nil
  ) async throws -> ContentPart {
    guard !data.isEmpty else { throw ImageAttachmentImportError.invalidImage }
    if mode == .ocr {
      guard let ocrProvider else { throw ImageAttachmentImportError.ocrProviderRequired }
      let result = try await ocrProvider.recognize(
        OCRRequest(imageData: data, mimeType: mimeType, filename: filename))
      let name = (filename as NSString).deletingPathExtension + ".md"
      return .file(FileContent(name: name, mimeType: "text/markdown", text: result.markdown))
    }

    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let originalWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let originalHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      throw ImageAttachmentImportError.invalidImage
    }
    let width = originalWidth.intValue
    let height = originalHeight.intValue
    guard width > 0, height > 0 else { throw ImageAttachmentImportError.invalidImage }

    guard let maximum = mode.maxDimension, max(width, height) > maximum else {
      return .image(
        ImageContent(
          source: .data(data), mimeType: mimeType, name: filename, width: width, height: height))
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximum,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw ImageAttachmentImportError.invalidImage
    }
    let encoded = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encoded, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw ImageAttachmentImportError.encodingFailed
    }
    CGImageDestinationAddImage(
      destination,
      thumbnail,
      [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ImageAttachmentImportError.encodingFailed
    }
    return .image(
      ImageContent(
        source: .data(encoded as Data),
        mimeType: "image/jpeg",
        name: (filename as NSString).deletingPathExtension + ".jpg",
        width: thumbnail.width,
        height: thumbnail.height))
  }
}

public enum OCRProviderError: LocalizedError, Equatable, Sendable {
  case noText
  case recognitionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .noText: "No text could be recognized in the image."
    case .recognitionFailed(let message): "OCR failed: \(message)"
    }
  }
}

public enum ImageAttachmentImportError: LocalizedError, Equatable, Sendable {
  case invalidImage
  case encodingFailed
  case ocrProviderRequired

  public var errorDescription: String? {
    switch self {
    case .invalidImage: "The image data is invalid or unsupported."
    case .encodingFailed: "The resized image could not be encoded."
    case .ocrProviderRequired: "OCR mode requires a configured OCR provider."
    }
  }
}
