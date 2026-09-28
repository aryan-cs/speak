import SwiftUI
import AppKit

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    let usesExternalGlass: Bool
    @EnvironmentObject var windowManager: MiniWindowManager
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 112
    private let expandedWidth: CGFloat = 300
    private let assistantWidth: CGFloat = 520
    // AssistantPanelView has a fixed height.
    private let assistantPanelHeight: CGFloat = 320
    private let liveTranscriptHeight: CGFloat = 57
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var pillWidth: CGFloat {
        if hasAssistantResponse { return assistantWidth }
        return hasLiveTranscript ? expandedWidth : compactWidth
    }

    private var pillHeight: CGFloat {
        if hasAssistantResponse { return controlBarHeight + assistantPanelHeight + 1 }
        return controlBarHeight + (hasLiveTranscript ? liveTranscriptHeight : 0)
    }

    private var pillCornerRadius: CGFloat {
        hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: pillCornerRadius,
            style: .continuous
        )
    }

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot
            )

            Spacer(minLength: 0)
        }
        .frame(height: controlBarHeight)
        // The compact pill stays button-free; closing is only offered for a finished assistant response.
        .overlay(alignment: .leading) {
            if shouldShowCloseButton {
                RecorderCloseButton(action: onCloseTapped)
                    .padding(.leading, 10)
            }
        }
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
                .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
                .onAppear(perform: syncWindowMetrics)
                .onChange(of: hasLiveTranscript) {
                    syncWindowMetrics()
                }
                .onChange(of: hasAssistantResponse) {
                    syncWindowMetrics()
                }
        }
    }

    private var pillContent: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(width: pillWidth, height: pillHeight)
        .allowsWindowActivationEvents()
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
