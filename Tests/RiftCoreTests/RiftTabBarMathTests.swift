import CoreGraphics
import Foundation
import Testing

@testable import RiftCore

@Suite struct TabBarMathTests {
	@Test func tabsShareTheRoomUpTo240AndNoLessThan64() {
		#expect(RiftTabBarMath.tabWidth(available: 1000, count: 2, fills: false) == 240)
		#expect(RiftTabBarMath.tabWidth(available: 1000, count: 2, fills: true) == 499.5)
		#expect(RiftTabBarMath.tabWidth(available: 1000, count: 1, fills: true) == 240)
		#expect(RiftTabBarMath.tabWidth(available: 401, count: 2, fills: false) == 200)
		#expect(RiftTabBarMath.tabWidth(available: 100, count: 10, fills: false) == 64)
		#expect(RiftTabBarMath.tabWidth(available: 500, count: 0, fills: false) == 240)
	}

	@Test func tabsSitOnePointApart() {
		let frames = RiftTabBarMath.tabFrames(leading: 10, width: 100, count: 3, midY: 20, height: 30)
		#expect(frames.map(\.minX) == [10, 111, 212])
		#expect(frames.allSatisfy { $0.minY == 5 && $0.height == 30 })
	}

	@Test func densitySizes() {
		#expect(RiftTabBarMath.buttonSize(density: .comfortable) == 34)
		#expect(RiftTabBarMath.buttonSize(density: .compact) == 32)
		#expect(RiftTabBarMath.buttonSize(density: .comfortable, tabCount: 1) == 32)
		#expect(RiftTabBarMath.tabHeight(density: .comfortable) == 30)
		#expect(RiftTabBarMath.tabHeight(density: .compact) == 28)
		#expect(RiftTabBarMath.spacing(density: .compact) == 4)
	}

	@Test func scrollingKeepsTwoPointsAtEachEnd() {
		// 10 tabs of 64 = 649 wide in a 300pt track: 649 - 296.
		#expect(RiftTabBarMath.maximumScrollOffset(tabWidth: 64, count: 10, trackWidth: 300) == 353)
		#expect(RiftTabBarMath.maximumScrollOffset(tabWidth: 64, count: 2, trackWidth: 300) == 0)
		// Revealing a tab past the end scrolls just enough.
		let offset = RiftTabBarMath.revealingOffset(
			current: 0, tabMinX: 400, tabMaxX: 464, trackWidth: 300, maximum: 353)
		#expect(offset == 168)
		let back = RiftTabBarMath.revealingOffset(
			current: 168, tabMinX: 65, tabMaxX: 129, trackWidth: 300, maximum: 353)
		#expect(back == 65)
	}

	@Test func draggedTabsRubberBandAtMostSixtyPoints() {
		#expect(RiftTabBarMath.rubberBanded(50, lower: 0, upper: 100) == 50)
		let past = RiftTabBarMath.rubberBanded(280, lower: 0, upper: 100)
		#expect(abs(past - (100 + (1 - exp(-1)) * 60)) < 0.0001)
		#expect(RiftTabBarMath.rubberBanded(-10_000, lower: 0, upper: 100) > -60.001)
		let origin = RiftTabBarMath.draggedOrigin(
			pointer: CGPoint(x: 150, y: 10), startPointer: CGPoint(x: 100, y: 10),
			startOrigin: CGPoint(x: 20, y: 4), size: CGSize(width: 100, height: 30),
			track: CGRect(x: 0, y: 4, width: 400, height: 30))
		#expect(origin == CGPoint(x: 70, y: 4))
	}

	@Test func reorderingNeedsTheCentrePastTheMidpointPlusAMargin() {
		let mids: [CGFloat] = [50, 151, 252]  // 101pt apart: margin 8 (a tenth is 10.1)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 105, current: 0, slotMidXs: mids) == 0)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 109, current: 0, slotMidXs: mids) == 1)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 260, current: 0, slotMidXs: mids) == 2)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 95, current: 2, slotMidXs: mids) == 1)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 90, current: 2, slotMidXs: mids) == 0)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 195, current: 2, slotMidXs: mids) == 2)
		// Narrow slots use a tenth of the distance.
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 33, current: 0, slotMidXs: [0, 60]) == 0)
		#expect(RiftTabBarMath.reorderedIndex(draggedMidX: 37, current: 0, slotMidXs: [0, 60]) == 1)
	}

	@Test func dividersHideBesideHighlightedTabs() {
		#expect(!RiftTabBarMath.showsDivider(atTab: 0, highlighted: []))
		#expect(RiftTabBarMath.showsDivider(atTab: 1, highlighted: [3]))
		#expect(!RiftTabBarMath.showsDivider(atTab: 3, highlighted: [3]))
		#expect(!RiftTabBarMath.showsDivider(atTab: 4, highlighted: [3]))
	}

	@Test func closingSelectsTheNextTabOrThePreviousOne() {
		#expect(RiftTabBarMath.selectionAfterClosing(index: 1, count: 3) == 1)
		#expect(RiftTabBarMath.selectionAfterClosing(index: 2, count: 3) == 1)
		#expect(RiftTabBarMath.selectionAfterClosing(index: 0, count: 1) == nil)
	}

	@Test func barLayout() {
		let layout = RiftTabBarLayout.resolve(
			bounds: CGRect(x: 0, y: 0, width: 600, height: 38), count: 3, density: .comfortable,
			leadingInset: 80)
		#expect(layout.newTabButtonFrame == CGRect(x: 564, y: 2, width: 34, height: 34))
		// 8pt between the track and the button.
		#expect(layout.trackFrame == CGRect(x: 82, y: 4, width: 474, height: 30))
		#expect(abs(layout.tabWidth - 472.0 / 3) < 0.0001)
		#expect(layout.tabFrames.first?.minX == 82)
		// A held width survives a close.
		let held = RiftTabBarLayout.resolve(
			bounds: CGRect(x: 0, y: 0, width: 600, height: 38), count: 2, density: .comfortable,
			leadingInset: 80, heldTabWidth: 158)
		#expect(held.tabWidth == 158)
	}

	@Test func tabItemLayout() {
		let item = RiftTabItemLayout.resolve(
			size: CGSize(width: 200, height: 30), density: .comfortable, showsCloseButton: true)
		#expect(item.cornerRadius == 15)
		#expect(item.closeButtonFrame == CGRect(x: 173, y: 4, width: 22, height: 22))
		#expect(item.titleFrame.minX == 12 && item.titleFrame.maxX == 169)
		#expect(item.dividerFrame.height == 18)
		let compact = RiftTabItemLayout.resolve(
			size: CGSize(width: 200, height: 28), density: .compact, showsCloseButton: false)
		#expect(compact.closeButtonFrame.minX == 175)
		#expect(compact.titleFrame.maxX == 188)
		let withIcon = RiftTabItemLayout.resolve(
			size: CGSize(width: 200, height: 30), density: .comfortable, showsCloseButton: false,
			hasIcon: true)
		#expect(withIcon.iconFrame == CGRect(x: 10, y: 7, width: 16, height: 16))
		#expect(withIcon.titleFrame.minX == 29)
	}
}

@Suite struct TabAnimationTests {
	@Test func defaultTimings() {
		let a = RiftTabAnimation.standard
		#expect(a.geometry == RiftTabTiming(0.28, .spring))
		#expect(a.insertion == RiftTabTiming(0.22))
		#expect(a.tabReturn == RiftTabTiming(0.42, .easeInOut))
		#expect(a.returnLayout == RiftTabTiming(0.4, .spring))
		#expect(a.hover == RiftTabTiming(0.14))
		#expect(a.divider == RiftTabTiming(0.2))
		#expect(a.titleClipping == RiftTabTiming(0.25))
		#expect(abs(RiftTabEasing.springDamping - 45.607) < 0.001)
	}

	@Test func titleFadesOverItsLast20Points() {
		#expect(RiftTabBarMath.titleFadeStart(titleWidth: 96, fieldWidth: 100) == nil)
		#expect(RiftTabBarMath.titleFadeStart(titleWidth: 97, fieldWidth: 100) == 0.8)
		#expect(RiftTabBarMath.titleFadeStart(titleWidth: 50, fieldWidth: 10) == 0)
	}

	@Test func placeholderAndSpacing() {
		#expect(RiftTabBarMath.placeholderCornerRadius(CGSize(width: 100, height: 30)) == 15)
		#expect(RiftTabBarMath.placeholderCornerRadius(CGSize(width: 100, height: 40)) == 16.5)
		#expect(RiftTabBarMath.trailingSpacing(density: .comfortable) == 8)
		#expect(RiftTabBarMath.trailingSpacing(density: .compact) == 6)
	}
}

@Suite struct TabListMathTests {
	@Test func rowsAre30PointsScaledByTheTextSize() {
		#expect(RiftTabListMath.titlePointSize(.small) == 11)
		#expect(RiftTabListMath.titlePointSize(.large) == 15)
		#expect(RiftTabListMath.rowHeight(.medium) == 30)
		#expect(RiftTabListMath.rowHeight(.small) == 25)  // 30 × 11/13 = 25.4
		#expect(RiftTabListMath.rowHeight(.large) == 34)  // 30 × 15/13 = 34.6
	}

	@Test func rowsStackInsideTheSideInset() {
		let rows = RiftTabListMath.rowFrames(count: 3, width: 240, top: 0, height: 30, inset: 10)
		#expect(rows.map(\.minY) == [0, 30, 60])
		#expect(rows.allSatisfy { $0.minX == 10 && $0.width == 220 })
		#expect(RiftTabListMath.sideInset(density: .compact) == 6)
	}

	@Test func sidebarRowsScaleTheCloseButtonAndCorners() {
		let row = RiftTabItemLayout.resolve(
			size: CGSize(width: 220, height: 34), density: .compact, showsCloseButton: true,
			vertical: true, scale: 15.0 / 13)
		#expect(row.closeButtonFrame.width == 25)  // 22 × 15/13 = 25.4
		#expect(row.cornerRadius == 17)  // min(19, 34/2)
		#expect(row.closeButtonFrame.maxX == CGFloat(220 - 12 + 7))  // no compact shift in the sidebar
	}
}
