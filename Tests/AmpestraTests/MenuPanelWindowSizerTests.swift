import AppKit
import XCTest
@testable import Ampestra

@MainActor
final class MenuPanelWindowSizerTests: XCTestCase {
    func testContentMeasuredBeforeAttachmentStillSizesWindow() async {
        let sizingView = MenuPanelWindowSizer.SizingView()
        sizingView.setFrameSize(NSSize(width: 336, height: 280))
        sizingView.scheduleWindowResize()
        await drainMainQueue()

        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(sizingView)
        await drainMainQueue()

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, sizingView.bounds.size)
        XCTAssertFalse(window.isOpaque)
    }

    func testReattachingSameContentSizesAndConfiguresNewWindow() async {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.close()
            secondWindow.close()
        }
        let sizingView = MenuPanelWindowSizer.SizingView()
        firstWindow.contentView?.addSubview(sizingView)
        sizingView.setFrameSize(NSSize(width: 336, height: 280))
        await drainMainQueue()

        sizingView.removeFromSuperview()
        secondWindow.contentView?.addSubview(sizingView)
        let topEdge = secondWindow.frame.maxY
        await drainMainQueue()

        XCTAssertEqual(secondWindow.contentRect(forFrameRect: secondWindow.frame).size, sizingView.bounds.size)
        XCTAssertEqual(secondWindow.frame.maxY, topEdge)
        XCTAssertFalse(secondWindow.isOpaque)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
