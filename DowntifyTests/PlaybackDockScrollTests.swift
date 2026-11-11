import SwiftUI
import XCTest
@testable import Downtify

@MainActor
final class PlaybackDockScrollTests: XCTestCase {
    func testFinalDownloadControlCanScrollAbovePlaybackDock() {
        let content = NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1_200)
                    Button("Download last song") { }
                        .frame(height: DowntifyStyle.minimumControlSize)
                        .background(LayoutProbe(tag: 1))
                }
            }
            .downtifyScrollEndClearance()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LayoutProbe(tag: 2).frame(height: 80)
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        guard let scrollView = descendants(of: window).compactMap({ $0 as? UIScrollView })
            .first(where: { $0.contentSize.height > $0.bounds.height }),
              let finalButton = descendants(of: window).first(where: { $0.tag == 1 }),
              let dock = descendants(of: window).first(where: { $0.tag == 2 }) else {
            XCTFail("Expected a scroll view, final action, and playback dock")
            return
        }

        let bottomOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        scrollView.setContentOffset(CGPoint(x: 0, y: max(0, bottomOffset)), animated: false)
        window.layoutIfNeeded()

        let buttonFrame = finalButton.convert(finalButton.bounds, to: window)
        let dockFrame = dock.convert(dock.bounds, to: window)
        XCTAssertLessThanOrEqual(buttonFrame.maxY + DowntifyStyle.Space.small, dockFrame.minY,
                                 "The final download action should remain fully visible above Now Playing")
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct LayoutProbe: UIViewRepresentable {
    let tag: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.tag = tag
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { }
}
