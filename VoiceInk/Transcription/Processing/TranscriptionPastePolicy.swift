import Foundation

enum TranscriptionPastePolicy {
    static func shouldPaste(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
