import Foundation
import MaiCore
import UIKit
import Vision

/// PocketMai's layout-aware OCR implementation. Keeping this behind MaiCore's
/// provider protocol lets the CLI use Vision directly while the app preserves
/// its richer Markdown reconstruction.
struct PocketMaiOCRProvider: MaiCore.OCRProvider {
  let descriptor = MaiCore.OCRProviderDescriptor(
    id: "pocketmai-vision",
    displayName: "PocketMai Vision OCR")

  func recognize(_ request: MaiCore.OCRRequest) async throws -> MaiCore.OCRResult {
    try await Task.detached(priority: .userInitiated) {
      guard let image = UIImage(data: request.imageData) else {
        throw MaiCore.OCRProviderError.noText
      }
      do {
        return MaiCore.OCRResult(markdown: try ImageOCRImporter.markdown(from: image))
      } catch {
        throw MaiCore.OCRProviderError.recognitionFailed(error.localizedDescription)
      }
    }.value
  }
}

/// Reads the text in a picture with Vision's on-device recogniser and emits
/// Markdown. The recognised lines are fed through the PDF importer's layout
/// reconstruction, so headings, paragraphs and lists are inferred the same way
/// they are for a scanned PDF page.
enum ImageOCRImporter {
  enum ImportError: LocalizedError {
    case noText

    var errorDescription: String? {
      switch self {
      case .noText:
        "No text could be recognized in the image."
      }
    }
  }

  static func markdown(from image: UIImage) throws -> String {
    guard let cgImage = uprightCGImage(image) else { throw ImportError.noText }
    let width = Double(cgImage.width)
    let height = Double(cgImage.height)
    guard width > 0, height > 0 else { throw ImportError.noText }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
      try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    } catch {
      throw ImportError.noText
    }

    var lines: [PDFImporter.Line] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      guard candidate.string.contains(where: { !$0.isWhitespace }) else { continue }

      let box = observation.boundingBox
      let frame = PDFImporter.Frame(
        left: Double(box.minX) * width,
        right: Double(box.maxX) * width,
        top: Double(1 - box.maxY) * height,
        bottom: Double(1 - box.minY) * height)
      // Recognised heights vary line by line, so they are quantised before they
      // are used to tell headings from body text.
      let size = max(2, (frame.height * 0.8 / 2).rounded() * 2)
      lines.append(
        PDFImporter.Line(
          runs: [PDFImporter.Run(text: candidate.string, size: size)],
          frame: frame,
          pageIndex: 0,
          pageWidth: width,
          pageHeight: height))
    }

    lines.sort { lhs, rhs in
      let tolerance = min(lhs.frame.height, rhs.frame.height) * 0.5
      if abs(lhs.frame.top - rhs.frame.top) > tolerance {
        return lhs.frame.top < rhs.frame.top
      }
      return lhs.frame.left < rhs.frame.left
    }

    let text = PDFImporter.markdown(lines: lines)
    guard !text.isEmpty else { throw ImportError.noText }
    return text
  }

  /// Vision wants the pixels the right way up, but a camera photo carries its
  /// rotation as EXIF orientation, so the image is redrawn upright. Very large
  /// photos are capped while redrawing; past ~2400 px recognition does not
  /// improve.
  private static func uprightCGImage(_ image: UIImage) -> CGImage? {
    let pixelSize = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale)
    guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
    let scale = min(1, 2400 / max(pixelSize.width, pixelSize.height))
    if image.imageOrientation == .up, scale == 1, let cgImage = image.cgImage {
      return cgImage
    }
    let target = CGSize(
      width: max(1, (pixelSize.width * scale).rounded()),
      height: max(1, (pixelSize.height * scale).rounded()))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }.cgImage
  }
}
