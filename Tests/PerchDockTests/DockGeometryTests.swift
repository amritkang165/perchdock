import CoreGraphics
import Testing
@testable import PerchDock

/// Dock layout math: base positions, magnification, hit-testing and drag slots.
@Suite("Dock geometry")
struct DockGeometryTests {
    /// Five icons with a divider in the middle, 50 pt icons, 1.5× magnification.
    private let objGeometry = DockGeometry(
        enmPosition: .bottom,
        fltIconSize: 50,
        fltMagnification: 1.5,
        arrBlnDivider: [false, false, true, false, false]
    )

    /// Allowed rounding error for layout positions, in points.
    private let fltTolerance: CGFloat = 0.01

    @Test("Base centers run left to right with the item widths and spacing between them")
    func baseCentersAreEvenlySpaced() {
        let arrFltCenters = (0..<objGeometry.intCount).map(objGeometry.baseCenter)
        // First icon starts after the side margin and bar padding.
        #expect(abs(arrFltCenters[0] - (objGeometry.fltBarStart + objGeometry.fltPadding + 25)) < fltTolerance)
        // Each step is half of each neighbor's width plus one gap.
        for intIndex in 1..<arrFltCenters.count {
            let fltExpected = objGeometry.baseWidth(intIndex - 1) / 2 + objGeometry.fltSpacing + objGeometry.baseWidth(intIndex) / 2
            #expect(abs(arrFltCenters[intIndex] - arrFltCenters[intIndex - 1] - fltExpected) < fltTolerance)
        }
    }

    @Test("Dividers are thin; icons use the icon size")
    func dividerIsThin() {
        #expect(objGeometry.baseWidth(2) == objGeometry.fltDividerWidth)
        #expect(objGeometry.baseWidth(2) < objGeometry.fltIconSize)
        #expect(objGeometry.baseWidth(0) == 50)
    }

    @Test("Without the cursor, nothing grows and the bar keeps its base length")
    func noHoverMeansNoMagnification() {
        let objLayout = objGeometry.layout(mouseMain: nil)
        #expect(objLayout.arrFltSizes == (0..<objGeometry.intCount).map(objGeometry.baseWidth))
        #expect(abs((objLayout.fltBarEnd - objLayout.fltBarStart) - objGeometry.fltBaseLength) < fltTolerance)
    }

    @Test("The icon under the cursor reaches full magnification and its neighbors grow less")
    func hoveredIconIsLargest() {
        let fltCursor = objGeometry.baseCenter(1)
        let objLayout = objGeometry.layout(mouseMain: fltCursor)
        #expect(abs(objLayout.arrFltSizes[1] - 75) < fltTolerance)
        #expect(objLayout.arrFltSizes[0] < objLayout.arrFltSizes[1])
        #expect(objLayout.arrFltSizes[0] > 50)
        // The divider never magnifies.
        #expect(objLayout.arrFltSizes[2] == objGeometry.fltDividerWidth)
    }

    @Test("Magnification keeps the point under the cursor still")
    func cursorPointStaysPut() {
        for intIndex in [0, 1, 3, 4] {
            let fltCursor = objGeometry.baseCenter(intIndex)
            let objLayout = objGeometry.layout(mouseMain: fltCursor)
            #expect(abs(objLayout.arrFltCenters[intIndex] - fltCursor) < 0.5, "icon \(intIndex) drifted")
        }
    }

    @Test("Magnification of 1× (off) never grows anything")
    func magnificationOff() {
        let objFlat = DockGeometry(enmPosition: .bottom, fltIconSize: 50, fltMagnification: 1, arrBlnDivider: [false, false, false])
        let objLayout = objFlat.layout(mouseMain: objFlat.baseCenter(1))
        #expect(objLayout.arrFltSizes == [50, 50, 50])
    }

    @Test("Hit-testing finds each item at its center, and nothing past the ends")
    func slotIndexFindsItems() {
        for intIndex in 0..<objGeometry.intCount {
            #expect(objGeometry.slotIndex(atMain: objGeometry.baseCenter(intIndex)) == intIndex)
        }
        #expect(objGeometry.slotIndex(atMain: 0) == nil)
        #expect(objGeometry.slotIndex(atMain: objGeometry.fltPanelLength) == nil)
    }

    @Test("Dragging the first item past the end drops it in the last slot")
    func dropSlotAtEnd() {
        let fltPastEnd = objGeometry.baseCenter(objGeometry.intCount - 1) + 100
        #expect(objGeometry.dropSlot(atMain: fltPastEnd, intDragIndex: 0) == objGeometry.intCount - 1)
        #expect(objGeometry.dropSlot(atMain: 0, intDragIndex: 3) == 0)
    }

    @Test("Side docks swap the panel's width and height", arguments: [DockPosition.left, .right])
    func verticalPanelSize(enmPosition: DockPosition) {
        let objSide = DockGeometry(enmPosition: enmPosition, fltIconSize: 50, fltMagnification: 1.5,
                                   arrBlnDivider: objGeometry.arrBlnDivider)
        #expect(objSide.objPanelSize.width == objGeometry.objPanelSize.height)
        #expect(objSide.objPanelSize.height == objGeometry.objPanelSize.width)
    }

    @Test("Compact mode packs the same items into a shorter bar")
    func compactIsShorter() {
        let objCompact = DockGeometry(enmPosition: .bottom, fltIconSize: 50, fltMagnification: 1.5, blnCompact: true,
                                      arrBlnDivider: objGeometry.arrBlnDivider)
        #expect(objCompact.fltBaseLength < objGeometry.fltBaseLength)
    }
}
