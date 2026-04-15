import CoreGraphics

struct BlackFrameDetector {
    let gridSize: Int
    let darkLumaThreshold: UInt8
    let veryDarkLumaThreshold: UInt8
    let maximumLumaRange: UInt8
    let minimumDarkRatio: Double

    static let screenOff = BlackFrameDetector(
        gridSize: 8,
        darkLumaThreshold: 5,
        veryDarkLumaThreshold: 6,
        maximumLumaRange: 3,
        minimumDarkRatio: 0.95
    )

    func isBlackFrame(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height

        guard width > 0 && height > 0,
              let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        guard bytesPerPixel >= 3 else { return false }
        var maximumLuma: UInt8 = 0
        var minimumLuma: UInt8 = 255
        var darkCount = 0
        var sampleCount = 0

        for gridY in 0..<gridSize {
            let y = (height * (2 * gridY + 1)) / (2 * gridSize)
            for gridX in 0..<gridSize {
                let x = (width * (2 * gridX + 1)) / (2 * gridSize)
                let offset = y * bytesPerRow + x * bytesPerPixel
                let luma = lumaForRGBSample(
                    red: bytes[offset],
                    green: bytes[offset + 1],
                    blue: bytes[offset + 2]
                )

                maximumLuma = max(maximumLuma, luma)
                minimumLuma = min(minimumLuma, luma)
                if luma < darkLumaThreshold {
                    darkCount += 1
                }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return false }

        let darkRatio = Double(darkCount) / Double(sampleCount)
        let isVeryDark = maximumLuma < veryDarkLumaThreshold
        let isUniform = (maximumLuma - minimumLuma) < maximumLumaRange
        let isMostlyDark = darkRatio >= minimumDarkRatio

        return isVeryDark && isUniform && isMostlyDark
    }

    private func lumaForRGBSample(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        UInt8((UInt16(red) * 54 + UInt16(green) * 183 + UInt16(blue) * 19) >> 8)
    }
}
