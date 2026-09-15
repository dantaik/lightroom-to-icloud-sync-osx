#if os(macOS)
import Foundation

/// Keeps the Mac awake for as long as a sync pass is running.
///
/// A check the Mac sleeps through is a check that has to start again: photos downloaded but not
/// yet imported are swept away at the start of the next pass, and on a Mac left alone all evening
/// nothing syncs at all, because every check comes due after the machine has already dozed off.
/// Holding an activity for the length of the pass defers idle sleep until it is over, and the Mac
/// is free to sleep again the moment it finishes.
///
/// What it deliberately does not do: the display still dims and sleeps on its own schedule, so a
/// check in the middle of the night does not light the room. Nor does it override sleep the user
/// asks for — closing the lid or choosing Sleep from the Apple menu still sends the Mac to sleep,
/// and on battery macOS may ignore the hold altogether. A pass cut short that way costs nothing
/// but the work it had done: the next check picks the photos up again.
final class SleepPreventer {
    /// What the hold is called in `pmset -g assertions`, for anyone asking their Mac why it is
    /// still awake.
    private static let reason = "Syncing photos from Lightroom to Photos"

    /// The activity being held, or nil while the Mac is free to sleep.
    private var activity: NSObjectProtocol?

    /// Starts holding idle sleep off. Beginning while already holding does nothing, so a second
    /// hold can never be left behind with nothing to end it.
    func begin() {
        guard activity == nil else { return }
        // `userInitiated` already disables idle system sleep; naming it too says which part of it
        // this is for. Idle *display* sleep is left out on purpose — see above.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: Self.reason)
    }

    /// Lets the Mac sleep again. Does nothing when sleep is not being held off.
    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
#endif
