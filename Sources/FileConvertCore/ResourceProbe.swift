import Darwin
import Foundation

/// Host-local measurements for deterministic test gates. Samples are compared over a fixed interval;
/// no production behavior depends on machine-specific timing.
public struct ProcessResourceSample: Sendable {
    public let monotonicNanoseconds: UInt64
    public let cpuNanoseconds: UInt64
    public let peakResidentBytes: UInt64
}

public enum ProcessResourceProbe {
    public static func sample() -> ProcessResourceSample {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let cpu = nanoseconds(usage.ru_utime) &+ nanoseconds(usage.ru_stime)
        return ProcessResourceSample(
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            cpuNanoseconds: cpu,
            peakResidentBytes: UInt64(max(0, usage.ru_maxrss))
        )
    }

    /// Returns CPU utilization over a measured interval, not a one-shot CPU reading.
    public static func averageCPUFraction(from start: ProcessResourceSample, to end: ProcessResourceSample) -> Double? {
        guard end.monotonicNanoseconds > start.monotonicNanoseconds, end.cpuNanoseconds >= start.cpuNanoseconds else { return nil }
        return Double(end.cpuNanoseconds - start.cpuNanoseconds) / Double(end.monotonicNanoseconds - start.monotonicNanoseconds)
    }

    private static func nanoseconds(_ value: timeval) -> UInt64 {
        UInt64(max(0, value.tv_sec)) * 1_000_000_000 + UInt64(max(0, value.tv_usec)) * 1_000
    }
}
