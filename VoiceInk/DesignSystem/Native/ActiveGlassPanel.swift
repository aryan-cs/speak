import AppKit

/// A floating panel whose Liquid Glass renders the way the Dock's does. AppKit flattens glass in
/// an inactive window into frosted gray; the recorder and its pop-ups never become key, so without
/// this their glass would always look inactive.
class ActiveGlassPanel: NSPanel {
    // Private AppKit hooks that glass asks about the window's active state. If a later macOS drops
    // them, nothing breaks: the panel just gets the inactive look again.
    @objc(_hasActiveAppearance) func glassHasActiveAppearance() -> Bool { true }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) func glassHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}
