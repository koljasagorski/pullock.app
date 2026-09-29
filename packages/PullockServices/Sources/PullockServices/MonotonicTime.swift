import Darwin

public enum MonotonicTime {
    /// Same continuous epoch in each process, including time spent asleep.
    public static var milliseconds: UInt64 {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return UInt64.max }
        let ticks = mach_continuous_time()
        // Split before multiplication; avoid uptime-dependent nanosecond overflow.
        let denominator = UInt64(info.denom) * 1_000_000
        let whole = ticks / denominator
        let remainder = ticks % denominator
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: UInt64(info.numer))
        let (fraction, fractionOverflow) = remainder.multipliedReportingOverflow(by: UInt64(info.numer))
        guard !overflow, !fractionOverflow else { return UInt64.max }
        let (result, finalOverflow) = scaled.addingReportingOverflow(fraction / denominator)
        return finalOverflow ? UInt64.max : result
    }
}
