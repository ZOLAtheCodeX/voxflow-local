import SwiftUI
import XCTest
@testable import VoxFlowApp

final class VFMotionTests: XCTestCase {
    func test_motion_gate() {
        XCTAssertFalse(VFMotion.allowsRepeatingAnimation(isActive: true, reduceMotion: true))
        XCTAssertTrue(VFMotion.allowsRepeatingAnimation(isActive: true, reduceMotion: false))
        XCTAssertFalse(VFMotion.allowsRepeatingAnimation(isActive: false, reduceMotion: false))
        XCTAssertFalse(VFMotion.allowsRepeatingAnimation(isActive: false, reduceMotion: true))
    }
}
