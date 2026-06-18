import CoreServices
import Foundation

/// Watches a directory subtree via FSEvents and calls `onChange` on the main queue, debounced.
/// Used for config/rules hot-reload and live audit.ndjson tailing (foundation: the app does all
/// long-lived watching in-process; there is no daemon).
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "pro.vhco.companion.filewatcher")

    public init(paths: [String], debounce: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // FSEvents coalescing latency; we additionally debounce below
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
