import Foundation

/// Watches one or more directories for any filesystem change (write/rename/delete
/// on the directory entry itself). Invokes `onChange` after a debounce interval.
final class FileWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fds: [Int32] = []
    private let queue = DispatchQueue(label: "FileWatcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void

    init(debounce: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    func start(urls: [URL]) {
        stop()
        for url in urls {
            let fd = open(url.path, O_EVTONLY)
            if fd < 0 { continue }
            fds.append(fd)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: queue
            )
            src.setEventHandler { [weak self] in self?.schedule() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        fds.removeAll()
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
