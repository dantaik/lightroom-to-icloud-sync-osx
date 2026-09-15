import Foundation

/// A monotonic timer, for the log lines that say where a pass spent its time.
///
/// `ContinuousClock` rather than `Date`: a pass can run for minutes, and a clock correction in
/// the middle of one must not be able to turn a download into a negative number of seconds.
public struct Stopwatch {
    private let start: ContinuousClock.Instant

    /// Starts timing now.
    public init() {
        start = ContinuousClock.now
    }

    /// How long it has been since the stopwatch was made. Reading it does not stop it.
    public var elapsed: Duration {
        ContinuousClock.now - start
    }

    public static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Steps faster than this are left out of a breakdown. Naming them crowds out the step that
    /// actually cost something, which is the only reason the breakdown is there.
    public static let worthNaming = Duration.milliseconds(1)

    /// "420 ms", "8.40 s", "12.3 s", "2 min 05.4 s" — short enough to sit at the end of a log
    /// line, and never so coarse that a fast step reads as having taken no time at all.
    public static func describe(_ duration: Duration) -> String {
        let total = seconds(duration)
        if total < 1 { return String(format: "%.0f ms", total * 1000) }
        if total < 10 { return String(format: "%.2f s", total) }
        if total < 60 { return String(format: "%.1f s", total) }
        let minutes = Int(total) / 60
        return String(format: "%d min %04.1f s", minutes, total - Double(minutes * 60))
    }
}

/// How long each step took for one photo, for the line the log ends up with.
public struct PhotoTimings: Equatable {
    /// Asking Photos whether the photo is already in the library.
    public var lookup: Duration = .zero
    public var didLookup = false
    /// Fetching the photo from Lightroom, whether a held rendition or a full-size render.
    public var download: Duration = .zero
    public var didDownload = false
    /// Reading the served size and bringing the photo down to the chosen one.
    public var resize: Duration = .zero
    /// Reading what the file says about itself and writing Lightroom's account of it back in.
    public var metadata: Duration = .zero
    /// Handing the file to Photos.
    public var importing: Duration = .zero
    public var didImport = false
    /// Reading and rewriting the ledger, which is written out whole every time it changes.
    public var ledger: Duration = .zero

    public init() {}

    public var total: Duration {
        lookup + download + resize + metadata + importing + ledger
    }

    /// "lookup 3.10 s, download 8.40 s, import 300 ms" — the steps that cost anything, in the
    /// order they happen, so a slow one is read off against the pipeline rather than hunted for.
    /// Empty when nothing took long enough to be worth naming.
    public var breakdown: String {
        let steps: [(name: String, duration: Duration)] = [
            ("lookup", lookup), ("download", download), ("resize", resize),
            ("metadata", metadata), ("import", importing), ("ledger", ledger),
        ]
        return steps
            .filter { $0.duration >= Stopwatch.worthNaming }
            .map { "\($0.name) \(Stopwatch.describe($0.duration))" }
            .joined(separator: ", ")
    }
}

/// Where a whole sync pass spent its time. Each field totals one step across the pass, so the
/// slow one is named in the log rather than having to be guessed at.
public struct SyncTimings: Equatable {
    /// Resolving the link, reading the share and listing the album: everything before the photos.
    public var listing: Duration = .zero
    /// Putting already-synced photos back into the configured album.
    public var refiling: Duration = .zero
    public var photosLookup: Duration = .zero
    public var photosLookups = 0
    public var download: Duration = .zero
    public var downloads = 0
    public var resize: Duration = .zero
    public var metadata: Duration = .zero
    public var importing: Duration = .zero
    public var imports = 0
    public var ledger: Duration = .zero

    public init() {}

    /// Folds one photo's steps into the pass totals.
    public mutating func add(_ photo: PhotoTimings) {
        photosLookup += photo.lookup
        if photo.didLookup { photosLookups += 1 }
        download += photo.download
        if photo.didDownload { downloads += 1 }
        resize += photo.resize
        metadata += photo.metadata
        importing += photo.importing
        if photo.didImport { imports += 1 }
        ledger += photo.ledger
    }

    /// Everything the pass spent time on, added up. Close to the pass's own duration but not the
    /// same as it: whatever falls between the measured steps lands in the gap.
    public var total: Duration {
        listing + refiling + photosLookup + download + resize + metadata + importing + ledger
    }

    /// Every step, longest first, with what each one is, so that naming the slow one is possible.
    private var steps: [(name: String, duration: Duration, count: Int?, because: String)] {
        [
            ("listing", listing, nil,
             "reading the share and paging through the album listing."),
            ("refiling", refiling, nil,
             "already-synced photos are being put back into the Photos album."),
            ("Photos lookups", photosLookup, photosLookups,
             "every photo not yet in the ledger is searched for across the library by capture date, which costs more the larger the library is."),
            ("downloads", download, downloads,
             "Lightroom builds each full-size photo on demand. The Small photo size takes a rendition it already holds instead, and downloads nothing full-size."),
            ("resizing", resize, nil,
             "each photo is decoded and scaled down on this Mac. A smaller photo size that Lightroom already holds skips this."),
            ("metadata", metadata, nil,
             "Lightroom's account of each photo is being written into the file."),
            ("imports", importing, imports,
             "Photos is doing the work; this app is waiting on it."),
            ("ledger", ledger, nil,
             "the ledger is written out whole every time a photo is recorded, so it costs more the more photos have been synced."),
        ].sorted { $0.duration > $1.duration }
    }

    /// The steps that cost anything, longest first, so the line opens with whatever the pass is
    /// actually waiting on:
    /// "Photos lookups 2 min 04.1 s (×12), downloads 58.1 s (×3), listing 1.20 s".
    public var summary: String {
        let named = steps
            .filter { $0.duration >= Stopwatch.worthNaming }
            .map { step -> String in
                guard let count = step.count else { return "\(step.name) \(Stopwatch.describe(step.duration))" }
                return "\(step.name) \(Stopwatch.describe(step.duration)) (×\(count))"
            }
        return named.isEmpty ? "too little to measure" : named.joined(separator: ", ")
    }

    /// Which step a slow pass was slow *because* of, in the log rather than left to be worked out
    /// from the numbers above it. Nil when the pass was quick, or when no single step dominated
    /// it and so there is nothing honest to point at.
    public var diagnosis: String? {
        let measured = total
        guard measured >= .seconds(1), let worst = steps.first else { return nil }
        let share = Stopwatch.seconds(worst.duration) / Stopwatch.seconds(measured)
        guard share >= 0.5 else { return nil }
        return "Most of that was \(worst.name) (\(Int((share * 100).rounded()))%): \(worst.because)"
    }
}
