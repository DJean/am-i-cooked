import CookedCore
import Darwin
import Foundation

private final class MonitorEvents: @unchecked Sendable {
    struct Pending {
        var refresh = false, quit = false
        var snapshots: [ProviderSnapshot]?
        var catalog: (value: ModelCatalog, complete: Bool)?
        var keys: [TerminalKey] = []
        var notice: String?
        var installedVersion: String?
    }
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending = Pending()

    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }

    func post(_ change: (inout Pending) -> Void = { _ in }) {
        lock.lock(); change(&pending); lock.unlock()
        continuation.yield(())
    }

    func take() -> Pending {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = Pending()
        return result
    }
}

// All terminal state is confined to the main actor / main dispatch queue.
private final class Terminal: @unchecked Sendable {
    private var original = termios()
    private var sources: [any DispatchSourceProtocol] = []
    private var active = false
    private var decoder = TerminalKeyDecoder()
    private var inputGeneration = 0

    init?(events: MonitorEvents) {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        active = true
        Self.write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J\u{1B}[H")
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { events.post { $0.quit = true }; return }
            guard count > 0 else { return }
            let keys = self.decoder.decode(Array(bytes.prefix(count)))
            events.post { $0.keys.append(contentsOf: keys) }
            self.inputGeneration += 1
            let generation = self.inputGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
                guard let self, self.inputGeneration == generation else { return }
                let escaped = self.decoder.flushEscape()
                if !escaped.isEmpty { events.post { $0.keys.append(contentsOf: escaped) } }
            }
        }
        sources.append(input)
        for number in [SIGINT, SIGTERM, SIGWINCH] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { events.post { if number != SIGWINCH { $0.quit = true } } }
            sources.append(source)
        }
        sources.forEach { $0.resume() }
    }

    func draw(_ text: String) {
        Self.write("\u{1B}[H\u{1B}[J" + text)
    }

    func restore() {
        guard active else { return }
        active = false
        sources.forEach { $0.cancel() }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        Self.write("\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l")
        for number in [SIGINT, SIGTERM, SIGWINCH] { signal(number, SIG_DFL) }
    }

    static var size: (rows: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0
        else { return (24, 80) }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    static func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
}

@main
private enum Cooked {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            FileHandle.standardOutput.write(Data((Build.version + "\n").utf8))
            return
        }
        if !arguments.isEmpty {
            let help = arguments.count == 1 && ["-h", "--help"].contains(arguments[0])
            let output = help ? FileHandle.standardOutput : .standardError
            output.write(Data("Usage: cooked\n".utf8))
            exit(help ? 0 : 2)
        }
        setlocale(LC_CTYPE, "UTF-8")
        let live = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), CursorProvider()]
        if !live {
            let snapshots = await fetchProviders(providers, now: Date())
            Terminal.write(DashboardRenderer.render(
                snapshots: snapshots, now: Date(), live: false, expanded: false,
                maxRows: .max, maxColumns: 106, notice: nil, loading: false, color: color
            ) + "\n")
            return
        }

        let events = MonitorEvents()
        guard let terminal = Terminal(events: events) else {
            FileHandle.standardError.write(Data("Could not enable terminal input.\n".utf8))
            return
        }
        defer { terminal.restore() }
        var snapshots: [ProviderSnapshot] = []
        var expanded = false, loading = true
        var notice: String?
        var tab = 0
        var timeline = TimelineState()
        var comparison: ModelCompareState?
        var catalog = ModelCatalog()
        let marks = LabMarks()
        var catalogSchedule = CatalogRefreshSchedule()
        var catalogRefresh: Task<Void, Never>?
        let companies = ModelCompany.configured()
        let marksTask = Task { await marks.prefetch(companies) }
        func requestCatalog() {
            guard catalogSchedule.begin(now: Date()) else { return }
            catalogRefresh = Task {
                let result = await ModelCatalogClient.fetch(companies: companies, onMetadata: { metadata in
                    if !Task.isCancelled { events.post { $0.catalog = (metadata, false) } }
                })
                if !Task.isCancelled { events.post { $0.catalog = (result, true) } }
            }
        }
        func draw() {
            let size = Terminal.size, now = Date()
            let content: String
            if tab == 0 {
                content = DashboardRenderer.render(snapshots: snapshots, now: now, live: true, expanded: expanded,
                    maxRows: size.rows, maxColumns: size.columns, notice: notice, loading: loading, color: color,
                    newModels: catalog.models.contains { $0.isNewRelease(now: now) })
            } else if let comparison {
                content = ModelCompareRenderer.frame(catalog: catalog, state: comparison,
                    rows: size.rows, columns: size.columns, color: color, notice: notice, now: now).text
            } else {
                content = TimelineRenderer.frame(catalog: catalog, companies: companies, state: timeline,
                    now: now, rows: size.rows, columns: size.columns, loading: catalogSchedule.loading, color: color, notice: notice).text
            }
            terminal.draw(content)
        }
        draw()
        requestCatalog()
        let updater = Task {
            while !Task.isCancelled {
                if let version = await SelfUpdater.run() {
                    events.post { $0.installedVersion = version }
                }
                do { try await Task.sleep(for: .seconds(3600)) } catch { break }
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                events.post { $0.refresh = true }
            }
        }
        var share: Task<Void, Never>?
        var refresh: Task<Void, Never>?
        defer { share?.cancel(); refresh?.cancel(); catalogRefresh?.cancel(); ticker.cancel(); updater.cancel(); marksTask.cancel() }
        events.post { $0.refresh = true }
        eventLoop: for await _ in events.stream {
            let pending = events.take()
            if pending.quit { break }
            if let message = pending.notice { notice = message; share = nil }
            if let version = pending.installedVersion { notice = "Updated to " + version + "; restart cooked to use it." }
            if let updated = pending.snapshots { snapshots = updated; loading = false; refresh = nil }
            if let updated = pending.catalog {
                catalog = updated.value.merging(previous: catalog)
                timeline.reconcile(models: TimelineRenderer.models(catalog: catalog, companies: companies), catalogUpdate: true)
                comparison?.reconcile(catalog: catalog)
                if updated.complete {
                    catalogSchedule.finish(now: Date(), succeeded: updated.value.error == nil && updated.value.priceError == nil)
                    catalogRefresh = nil
                }
            }
            for rawKey in pending.keys {
                notice = nil
                let searching = tab == 1 ? comparison?.searching == true : false
                if let command = rawKey.globalCommand(searching: searching) {
                    switch command {
                    case .quit: break eventLoop
                    case .tabLeft, .tabRight:
                        tab = 1 - tab
                        if tab == 1 { requestCatalog() }
                    case .share, .shareCompany:
                        if tab == 0 && loading { continue }
                        guard share == nil else { continue }
                        let savedTab = tab, savedSnapshots = snapshots, savedCatalog = catalog
                        let savedTimeline = timeline, savedComparison = comparison
                        share = Task.detached {
                            let message: String
                            do {
                                let companyID = savedTimeline.selectedID.map { String($0.prefix { $0 != "/" }) }
                                var mark: Data?
                                if savedTab == 1, savedComparison == nil, let companyID { mark = await marks.data(for: companyID) }
                                try Task.checkCancellation()
                                let file = try savedTab == 0 ? ShareCardRenderer.save(snapshots: savedSnapshots)
                                    : ModelShareCard.save(catalog: savedCatalog, companies: companies, timeline: savedTimeline,
                                        comparison: savedComparison, companyCard: command == .shareCompany, mark: mark)
                                message = "Saved " + file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/")
                            } catch { message = error.localizedDescription }
                            if !Task.isCancelled { events.post { $0.notice = message } }
                        }
                    default: break
                    }
                    continue
                }
                if tab == 1, var state = comparison {
                    let size = Terminal.size
                    let bounds = state.searching ? nil : ModelCompareRenderer.frame(catalog: catalog, state: state,
                        rows: size.rows, columns: size.columns, color: false, now: Date())
                    let close = state.handle(rawKey, catalog: catalog, scrollLimit: bounds?.scrollLimit ?? 0, modelLimit: bounds?.modelLimit ?? 0)
                    comparison = close ? nil : state
                    continue
                }
                let key = rawKey.command
                switch key {
                case .toggle:
                    if tab == 0 { expanded.toggle(); notice = nil }
                    else {
                        let size = Terminal.size
                        let bounds = TimelineRenderer.frame(catalog: catalog, companies: companies, state: timeline,
                            now: Date(), rows: size.rows, columns: size.columns, loading: catalogSchedule.loading, color: false)
                        timeline.handle(key, models: TimelineRenderer.models(catalog: catalog, companies: companies),
                            scrollLimit: bounds.scrollLimit, paneRows: max(1, size.rows - 6))
                    }
                case .up, .down, .previous, .next, .enter, .escape:
                    if tab == 1 {
                        timeline.handle(key, models: TimelineRenderer.models(catalog: catalog, companies: companies), scrollLimit: 0)
                    }
                case .compare:
                    if tab == 1 {
                        var state = ModelCompareState()
                        state.selectedIDs = timeline.selectedID.map { [$0] } ?? []
                        comparison = state
                    }
                default: break
                }
            }
            if pending.refresh {
                requestCatalog()
                notice = nil
                if refresh == nil {
                    refresh = Task {
                        let result = await fetchProviders(providers, now: Date())
                        if !Task.isCancelled { events.post { $0.snapshots = result } }
                    }
                }
            }
            draw()
        }
    }
}
