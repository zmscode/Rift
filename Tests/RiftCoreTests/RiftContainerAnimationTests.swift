import CoreGraphics
import Testing

@testable import RiftCore

@Suite struct ContainerAnimationTests {
	@Test func paneTakesItsShareOfTheChange() {
		// A pane half as wide as the container gets half of the width change.
		let size = RiftContainerAnimationMath.predictedSize(
			paneSize: CGSize(width: 400, height: 300), contentWidth: 800, widthChange: -200)
		#expect(size == CGSize(width: 300, height: 300))
	}

	@Test func shareIsClampedToOne() {
		// A pane wider than the reported container still only takes the whole change.
		let size = RiftContainerAnimationMath.predictedSize(
			paneSize: CGSize(width: 900, height: 200), contentWidth: 800, widthChange: 100)
		#expect(size == CGSize(width: 1000, height: 200))
	}

	@Test func noPredictionForDegenerateInput() {
		#expect(
			RiftContainerAnimationMath.predictedSize(
				paneSize: CGSize(width: 100, height: 100), contentWidth: 0, widthChange: 50) == nil)
		#expect(
			RiftContainerAnimationMath.predictedSize(
				paneSize: CGSize(width: 100, height: 100), contentWidth: 100, widthChange: -100)
				== nil)
		#expect(
			RiftContainerAnimationMath.predictedSize(
				paneSize: CGSize(width: 100, height: 0), contentWidth: 100, widthChange: 10) == nil)
	}

	@Test func layoutTargetTakesItsShare() {
		// A layout filling half of the container gets half of the change.
		let size = RiftContainerAnimationMath.targetLayoutSize(
			layoutSize: CGSize(width: 400, height: 300), contentWidth: 800, widthChange: -200)
		#expect(size == CGSize(width: 300, height: 300))
	}

	@Test func layoutTargetTakesWholeChangeWithoutContentWidth() {
		let size = RiftContainerAnimationMath.targetLayoutSize(
			layoutSize: CGSize(width: 400, height: 300), contentWidth: nil, widthChange: -100)
		#expect(size == CGSize(width: 300, height: 300))
		let zero = RiftContainerAnimationMath.targetLayoutSize(
			layoutSize: CGSize(width: 400, height: 300), contentWidth: 0, widthChange: 50)
		#expect(zero == CGSize(width: 450, height: 300))
	}

	@Test func layoutTargetRejectsEmptyResult() {
		#expect(
			RiftContainerAnimationMath.targetLayoutSize(
				layoutSize: CGSize(width: 100, height: 300), contentWidth: nil, widthChange: -100)
				== nil)
	}
}
