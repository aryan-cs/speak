import SwiftUI
import AppKit

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    let usesExternalGlass: Bool
    @EnvironmentObject var windowManager: MiniWindowManager
    @AppStorage("showLiveTextPreview") private var showLiveTextPreview = false

    init(stateProvider: S, recorder: Recorder, usesExternalGlass: Bool = false) {
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.usesExternalGlass = usesExternalGlass
    }

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 112
    private let expandedWidth: CGFloat = 300
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var pillWidth: CGFloat {
        hasLiveTranscript ? expandedWidth : compactWidth
    }

    private var pillHeight: CGFloat {
        controlBarHeight + (hasLiveTranscript ? 57 : 0)
    }

    private var pillCornerRadius: CGFloat {
        hasLiveTranscript ? expandedCornerRadius : compactCornerRadius
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: pillCornerRadius,
            style: .continuous
        )
    }

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTextPreview
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeter: recorder.audioMeter
            )

            Spacer(minLength: 0)
        }
        .frame(height: controlBarHeight)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        if windowManager.isVisible {
            pill
                .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
                .onAppear(perform: syncWindowMetrics)
                .onChange(of: hasLiveTranscript) {
                    syncWindowMetrics()
                }
        }
    }

    private var pillContent: some View {
        VStack(spacing: 0) {
            transcriptSection
            controlBar
        }
        .frame(width: pillWidth, height: pillHeight)
    }

    @ViewBuilder
    private var pill: some View {
        if usesExternalGlass {
            pillContent
        } else {
            pillContent
                .background(Color.black)
                .clipShape(pillShape)
        }
    }

    private func syncWindowMetrics() {
        windowManager.updateContentMetrics(
            width: pillWidth,
            height: pillHeight,
            cornerRadius: pillCornerRadius
        )
    }
}
