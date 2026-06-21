import Foundation

/// Runs the static analyzer over many bundles concurrently and streams each
/// result back as it completes. Reuses the exact same `StaticAnalyzer` +
/// `RiskScorer` the single-app flow uses — batch mode adds orchestration, not
/// a second analysis path.
///
/// Concurrency is bounded: each analysis shells out to `codesign`/`spctl`/
/// `stapler`, so we keep a small window of in-flight work rather than spawning
/// one subprocess storm per app. Results arrive out of order (fastest first);
/// the view-model appends them live and the table re-sorts.
public struct BatchAnalyzer: Sendable {

    public init() {}

    /// A sensible default in-flight window: enough to keep cores busy without
    /// flooding the system with codesign/spctl subprocesses.
    public static var defaultConcurrency: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
    }

    public enum Event: Sendable {
        case started(total: Int)
        case result(BatchAppResult)
        case progress(completed: Int, total: Int)
        case finished(total: Int)
    }

    /// Stream analyses for `urls`. The returned stream yields `.started`
    /// first, then interleaved `.result`/`.progress` per app, then
    /// `.finished`. Cancelling the consuming task (or terminating the stream)
    /// cancels the orchestration; in-flight analyses are allowed to finish.
    public func stream(urls: [URL],
                       maxConcurrent: Int = BatchAnalyzer.defaultConcurrency) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let work = Task {
                let total = urls.count
                continuation.yield(.started(total: total))
                guard total > 0 else {
                    continuation.yield(.finished(total: 0))
                    continuation.finish()
                    return
                }

                await withTaskGroup(of: BatchAppResult.self) { group in
                    let limit = max(1, min(maxConcurrent, total))
                    var next = 0
                    var completed = 0

                    while next < limit {
                        let url = urls[next]; next += 1
                        group.addTask { Self.analyzeOne(url) }
                    }

                    for await result in group {
                        if Task.isCancelled { break }
                        completed += 1
                        continuation.yield(.result(result))
                        continuation.yield(.progress(completed: completed, total: total))
                        if next < total {
                            let url = urls[next]; next += 1
                            group.addTask { Self.analyzeOne(url) }
                        }
                    }
                    group.cancelAll()
                }

                continuation.yield(.finished(total: total))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Convenience for non-streaming callers (CLI, tests): analyse everything
    /// and return the collected results.
    public func analyzeAll(urls: [URL],
                           maxConcurrent: Int = BatchAnalyzer.defaultConcurrency) async -> [BatchAppResult] {
        var out: [BatchAppResult] = []
        out.reserveCapacity(urls.count)
        for await event in stream(urls: urls, maxConcurrent: maxConcurrent) {
            if case .result(let r) = event { out.append(r) }
        }
        return out
    }

    // MARK: - One bundle

    /// Analyse a single bundle, never throwing — failures become a
    /// `.analysisFailed` result so a bad bundle can't sink the whole scan.
    /// A fresh `StaticAnalyzer` per call keeps this free of shared mutable
    /// state across the task group.
    static func analyzeOne(_ url: URL) -> BatchAppResult {
        let auditorVersion = RunReport.currentAuditorVersion
        // Reuse a cached report for an unchanged app (e.g. a re-scan), and seed
        // the cache otherwise so a later single-app drill-in is instant rather
        // than re-paying for the analysis we're doing right now.
        if let cached = StaticReportCache.shared.load(for: url, auditorVersion: auditorVersion) {
            let risk = RiskScorer().score(staticReport: cached)
            return BatchAppResult.derive(url: url, report: cached, risk: risk)
        }
        do {
            let report = try StaticAnalyzer().analyze(bundleAt: url)
            StaticReportCache.shared.store(report, for: url, auditorVersion: auditorVersion)
            let risk = RiskScorer().score(staticReport: report)
            return BatchAppResult.derive(url: url, report: report, risk: risk)
        } catch {
            let name = url.deletingPathExtension().lastPathComponent
            return BatchAppResult.failed(url: url, name: name,
                                         error: error.localizedDescription)
        }
    }
}
