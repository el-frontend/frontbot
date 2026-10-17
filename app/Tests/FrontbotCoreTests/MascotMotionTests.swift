import XCTest
import simd
@testable import FrontbotCore

final class MascotMotionTests: XCTestCase {
    let times = stride(from: 0.0, through: 6.0, by: 0.05).map { $0 }

    func close(_ a: MascotPose, _ b: MascotPose, _ eps: Float = 1e-3) -> Bool {
        let angle = { (x: Float, y: Float) in abs(remainder(x - y, 2 * .pi)) < eps }
        return simd_distance(a.offset, b.offset) < eps && angle(a.yaw, b.yaw) && angle(a.pitch, b.pitch) && angle(a.roll, b.roll)
            && simd_distance(a.scale, b.scale) < eps && abs(a.glow - b.glow) < eps
    }

    func testEveryStateStaysWithinLimits() {
        for state in MascotState.allCases {
            for t in times {
                let p = MascotMotion.pose(state, t: t, reduceMotion: false)
                XCTAssertLessThanOrEqual(simd_length(p.offset), 0.2, "\(state) t=\(t)")
                XCTAssertLessThanOrEqual(abs(p.pitch), 0.4); XCTAssertLessThanOrEqual(abs(p.roll), 0.4)
                XCTAssertTrue((0.85...1.15).contains(p.scale.x) && (0.85...1.15).contains(p.scale.y) && (0.85...1.15).contains(p.scale.z), "\(state) t=\(t)")
                XCTAssertTrue((0...1).contains(p.glow))
            }
        }
    }

    func testLoopingStatesCloseTheirCycle() {
        for state in MascotState.allCases {
            guard let period = MascotMotion.period(state) else { continue }
            for t in [0.0, 0.3, 1.1, 2.7] {
                XCTAssertTrue(close(MascotMotion.pose(state, t: t, reduceMotion: false), MascotMotion.pose(state, t: t + period, reduceMotion: false)), "\(state) t=\(t)")
            }
        }
        XCTAssertNil(MascotMotion.period(.happy)); XCTAssertNil(MascotMotion.period(.sad))
    }

    func testHappyEndsFacingForwardAtRest() {
        let end = MascotMotion.pose(.happy, t: 1.6, reduceMotion: false)
        XCTAssertTrue(close(end, MascotPose(offset: .zero, yaw: 0, pitch: 0, roll: 0, scale: [1, 1, 1], glow: end.glow)), "acaba de frente y quieta")
    }

    func testReduceMotionKeepsThePoseStill() {
        for state in MascotState.allCases {
            for t in times {
                let p = MascotMotion.pose(state, t: t, reduceMotion: true)
                XCTAssertEqual(p.offset, .zero); XCTAssertEqual(p.yaw, 0); XCTAssertEqual(p.pitch, 0); XCTAssertEqual(p.roll, 0)
                XCTAssertEqual(p.scale, [1, 1, 1])
            }
        }
        XCTAssertNotEqual(MascotMotion.pose(.thinking, t: 0, reduceMotion: true).glow, MascotMotion.pose(.idle, t: 0, reduceMotion: true).glow, "el brillo sí cambia")
    }

    func testBlendIsContinuousBetweenStates() {
        let a = MascotMotion.pose(.happy, t: 0.3, reduceMotion: false), b = MascotMotion.pose(.talking, t: 0, reduceMotion: false)
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 0), a))
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 1), b))
        let mid = MascotMotion.blend(a, b, progress: 0.5)
        XCTAssertEqual(mid.offset.y, (a.offset.y + b.offset.y) / 2, accuracy: 1e-4)
        XCTAssertTrue(close(MascotMotion.blend(a, b, progress: 3), b), "progress se limita a 0…1")
    }

    func testOnlyRestNeedsNoFrames() {
        XCTAssertFalse(MascotMotion.needsFrames(.idle, reduceMotion: true))
        XCTAssertTrue(MascotMotion.needsFrames(.idle, reduceMotion: false))
        XCTAssertTrue(MascotMotion.needsFrames(.thinking, reduceMotion: true), "el brillo pulsa")
    }
}
