import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from idle sleep while any window's agent is working (D153):
/// a long turn shouldn't stop because nobody touched the keyboard. Closing the
/// lid still sleeps it; macOS doesn't let apps prevent that.
@MainActor
final class AgentWakeLock {
    static let shared = AgentWakeLock()
    static let key = "orbit.agents.keepAwake"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            update()
        }
    }

    private var assertion: IOPMAssertionID?
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        observe()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor in AgentWakeLock.shared.observe() }
        }
    }

    private func update() {
        let working = AgentDirectory.shared.workingCount > 0
        if working, isEnabled, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "An agent is working in Orbit" as CFString, &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !(working && isEnabled), let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
