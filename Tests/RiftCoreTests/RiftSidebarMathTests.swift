import CoreGraphics
import Testing

@testable import RiftCore

@Suite struct SidebarMathTests {
	@Test func widthStaysBetween167AndSixtyPercentUpTo480() {
		#expect(RiftSidebarMath.clampedWidth(100, containerWidth: 1200) == 167)
		#expect(RiftSidebarMath.clampedWidth(300.4, containerWidth: 1200) == 300)
		#expect(RiftSidebarMath.clampedWidth(900, containerWidth: 1200) == 480)
		#expect(RiftSidebarMath.clampedWidth(500, containerWidth: 600) == 360)
		#expect(RiftSidebarMath.maximumWidth(containerWidth: 200) == 167)
		#expect(RiftSidebarMath.maximumWidth(containerWidth: 0) == 480)
	}

	@Test func leftSidebarReservesRoomAsItFolds() {
		func room(_ p: CGFloat, fullScreen: Bool = false, density: RiftChromeDensity = .comfortable, hides: Bool = false) -> CGFloat {
			RiftSidebarMath.leadingButtonRoom(
				position: .left, collapseProgress: p, isFullScreen: fullScreen, density: density,
				hidesToggle: hides)
		}
		#expect(room(0) == 0)
		#expect(room(1) == 116)
		#expect(room(0.5) == 58)
		#expect(room(1, density: .compact) == 110)
		#expect(room(1, fullScreen: true) == 32)
		#expect(room(1, hides: true) == 80)
	}

	@Test func rightSidebarKeepsTheButtonsOverThePanes() {
		#expect(
			RiftSidebarMath.leadingButtonRoom(
				position: .right, collapseProgress: 0.3, isFullScreen: false, density: .comfortable,
				hidesToggle: false) == 76)
		#expect(
			RiftSidebarMath.trailingButtonRoom(position: .right, collapseProgress: 1, hidesToggle: false)
				== 34)
		#expect(
			RiftSidebarMath.trailingButtonRoom(position: .left, collapseProgress: 1, hidesToggle: false)
				== 0)
	}

	@Test func toggleSitsBesideTheWindowButtons() {
		#expect(
			RiftSidebarMath.toggleFrame(
				position: .left, containerWidth: 1000, isFullScreen: false, density: .comfortable)
				== CGRect(x: 93, y: 11, width: 28, height: 28))
		#expect(
			RiftSidebarMath.toggleFrame(
				position: .left, containerWidth: 1000, isFullScreen: false, density: .compact)
				== CGRect(x: 85, y: 5, width: 28, height: 28))
		#expect(
			RiftSidebarMath.toggleFrame(
				position: .right, containerWidth: 1000, isFullScreen: false, density: .comfortable)
				== CGRect(x: 961, y: 11, width: 28, height: 28))
	}

	@Test func swipeNeeds44PointsMostlySideways() {
		#expect(!RiftSidebarMath.swipeIsRecognized(travel: CGSize(width: 40, height: 0)))
		#expect(RiftSidebarMath.swipeIsRecognized(travel: CGSize(width: -44, height: 10)))
		#expect(!RiftSidebarMath.swipeIsRecognized(travel: CGSize(width: 50, height: 40)))
		#expect(RiftSidebarMath.swipeCollapses(dx: -50, position: .left))
		#expect(!RiftSidebarMath.swipeCollapses(dx: -50, position: .right))
	}

	@Test func foldingShrinksTheWindowDownTo480Or720MinusTheSidebar() {
		#expect(RiftSidebarMath.collapsedWindowShrink(windowWidth: 1200, sidebarWidth: 240) == 240)
		// 720 − 240 = 480: a 600pt window can only give 120.
		#expect(RiftSidebarMath.collapsedWindowShrink(windowWidth: 600, sidebarWidth: 240) == 120)
		#expect(RiftSidebarMath.collapsedWindowShrink(windowWidth: 400, sidebarWidth: 240) == 0)
		#expect(RiftSidebarMath.collapsedWindowMinimumWidth(shrink: 240) == 480)
		#expect(RiftSidebarMath.collapsedWindowMinimumWidth(shrink: 100) == 620)
	}
}

@Suite struct SidebarFoldTests {
	@Test func aWindowThatFillsItsScreenKeepsItsWidth() {
		let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
		#expect(
			RiftSidebarMath.windowFillsScreen(
				windowFrame: CGRect(x: 0, y: 0, width: 1400, height: 800), screenFrame: screen))
		#expect(
			!RiftSidebarMath.windowFillsScreen(
				windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), screenFrame: screen))
		#expect(
			!RiftSidebarMath.windowFillsScreen(
				windowFrame: CGRect(x: 3000, y: 0, width: 1440, height: 800), screenFrame: screen))
	}

	@Test func foldsTakeTheSpringsSettlingTimeOrThreeTenths() {
		#expect(RiftSidebarMath.foldDuration(curve: .linear) == 0.3)
		#expect(RiftSidebarMath.foldDuration(curve: .snappy) == RiftMotionCurve.snappy.settlingDuration)
	}
}
