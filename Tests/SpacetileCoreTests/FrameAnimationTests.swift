import CoreGraphics
import Foundation
import Testing
@testable import SpacetileCore

@Suite struct FrameAnimations {
    let start: [WindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100), 2: CGRect(x: 200, y: 0, width: 100, height: 100)]

    @Test func onlyWindowsThatMoveAndHaveAStart() {
        let animation = FrameAnimation(from: start, to: [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 100, y: 0, width: 200, height: 100),
            3: CGRect(x: 0, y: 0, width: 50, height: 50),
        ])
        #expect(Array(animation.moves.keys) == [2])
        #expect(!animation.isEmpty)
        #expect(FrameAnimation(from: start, to: start).isEmpty)
    }

    @Test func startsAndEndsOnTheFrames() {
        let end: [WindowID: CGRect] = [1: CGRect(x: 50, y: 20, width: 300, height: 400), 2: CGRect(x: 0, y: 0, width: 10, height: 10)]
        let animation = FrameAnimation(from: start, to: end)
        #expect(animation.frames(at: 0) == start)
        #expect(animation.frames(at: 1) == end)
        #expect(animation.frames(at: 2) == end)
    }

    @Test func easesOutBetween() {
        #expect(FrameAnimation.ease(0) == 0)
        #expect(FrameAnimation.ease(1) == 1)
        #expect(FrameAnimation.ease(0.5) > 0.5)
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map(FrameAnimation.ease)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func midwayIsBetweenAndWhole() {
        let animation = FrameAnimation(from: [1: CGRect(x: 0, y: 0, width: 100, height: 100)], to: [1: CGRect(x: 101, y: 0, width: 301, height: 100)])
        let mid = animation.frames(at: 0.5)[1]!
        #expect(mid.minX > 0 && mid.minX < 101)
        #expect(mid.width > 100 && mid.width < 301)
        #expect(mid == mid.integral)
    }

    @Test func offByDefault() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings.default))
        #expect(!decoded.animatesWindows)
        var settings = decoded
        settings.animateWindows = true
        #expect(settings.animatesWindows)
    }
}
