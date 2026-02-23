import XCTest
@testable import VoxFlowApp

final class WhisperKitSTTServiceTests: XCTestCase {

    // MARK: - PCM conversion

    func testConvertPCMInt16ToFloat() {
        // Silence: all zeros
        let silence = Data(repeating: 0, count: 4) // 2 samples of Int16(0)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(silence)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001)
    }

    func testConvertPCMMaxPositive() {
        // Int16.max = 32767
        var sample = Int16.max
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
    }

    func testConvertPCMMaxNegative() {
        // Int16.min = -32768
        var sample = Int16.min
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], -1.0, accuracy: 0.001)
    }

    func testConvertPCMOddByteCountTruncates() {
        // 3 bytes -> only 1 complete Int16 sample (2 bytes), last byte dropped
        let data = Data([0x00, 0x00, 0xFF])
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Model path resolution

    func testResolveModelFolder() {
        let modelsDir = "/tmp/test-models"
        let folder = WhisperKitSTTService.resolveModelFolder(
            modelsDir: modelsDir,
            modelName: "openai_whisper-small.en"
        )
        XCTAssertEqual(folder, "/tmp/test-models/whisperkit-coreml__openai_whisper-small.en")
    }
}
