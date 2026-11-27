import Darwin
import SwiftUI

/// Live load of this Mac: processor, memory and how warm it runs. Sampled every two seconds while visible.
@MainActor final class SystemMonitor: ObservableObject {
    static let samples = 60
    /// Processor load from 0 to 1, oldest first.
    @Published private(set) var cpu = [Double]()
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    private var previous: host_cpu_load_info?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        if let load = Self.cpuLoad() {
            if let previous {
                let ticks = { (info: host_cpu_load_info) in
                    (Double(info.cpu_ticks.0), Double(info.cpu_ticks.1), Double(info.cpu_ticks.2), Double(info.cpu_ticks.3))
                }
                let now = ticks(load), before = ticks(previous)
                let user = now.0 - before.0, system = now.1 - before.1, idle = now.2 - before.2, nice = now.3 - before.3
                let total = user + system + idle + nice
                if total > 0 { cpu = Array((cpu + [(user + system + nice) / total]).suffix(Self.samples)) }
            }
            previous = load
        }
        if let used = Self.memoryInUse() { memoryUsed = used }
        thermal = ProcessInfo.processInfo.thermalState
    }

    nonisolated static func cpuLoad() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Memory apps hold: active, wired and compressed pages, as Activity Monitor counts "memory used" roughly.
    nonisolated static func memoryInUse() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}

/// "This Mac" in the computer tab: a load curve, memory and temperature state.
struct MacMonitor: View {
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("This Mac", "Dieser Mac")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Desk.dim)
                Spacer()
                thermalChip
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t("Processor", "Prozessor")).font(.system(size: 12)).foregroundStyle(Desk.dim)
                    Spacer()
                    Text("\(Int(((monitor.cpu.last ?? 0) * 100).rounded())) %").font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                Sparkline(values: monitor.cpu, capacity: SystemMonitor.samples).frame(height: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t("Memory", "Arbeitsspeicher")).font(.system(size: 12)).foregroundStyle(Desk.dim)
                    Spacer()
                    Text(Self.gigabytes(monitor.memoryUsed) + " / " + Self.gigabytes(monitor.memoryTotal))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                }
                let share = monitor.memoryTotal > 0 ? Double(monitor.memoryUsed) / Double(monitor.memoryTotal) : 0
                GeometryReader { area in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(share > 0.9 ? Desk.warning : Desk.accent).frame(width: max(4, area.size.width * min(1, share)))
                    }
                }.frame(height: 5)
            }
        }
        .padding(14).background(Desk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// macOS tells apps how warm the Mac runs in four steps; exact core temperatures need administrator rights.
    private var thermalChip: some View {
        let (title, color): (String, Color) = switch monitor.thermal {
        case .nominal: (t("Cool", "Kühl"), Desk.success)
        case .fair: (t("Warm", "Warm"), Desk.accent)
        case .serious: (t("Hot", "Heiß"), Desk.warning)
        case .critical: (t("Very hot", "Sehr heiß"), Desk.danger)
        @unknown default: ("–", Desk.dim)
        }
        return HStack(spacing: 5) {
            Image(systemName: "thermometer.medium").font(.system(size: 10.5))
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 8).frame(height: 22).background(color.opacity(0.14), in: Capsule())
        .help(t("How warm the Mac runs, as macOS reports it. When it gets hot, macOS slows it down.",
                "Wie warm der Mac läuft, wie macOS es meldet. Wird er heiß, bremst macOS ihn.")).accessibilityElement(children: .combine)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}

/// Small area chart of values from 0 to 1; new values enter on the right.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int

    var body: some View {
        GeometryReader { area in
            let step = area.size.width / CGFloat(max(1, capacity - 1))
            let offset = CGFloat(capacity - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: offset + CGFloat(index) * step, y: area.size.height * (1 - CGFloat(min(1, max(0, value)))))
            }
            ZStack {
                // Faint grid at 25, 50 and 75 %.
                ForEach([0.25, 0.5, 0.75], id: \.self) { level in
                    Path { $0.move(to: CGPoint(x: 0, y: area.size.height * level)); $0.addLine(to: CGPoint(x: area.size.width, y: area.size.height * level)) }
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                }
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: area.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: area.size.height))
                        path.closeSubpath()
                    }.fill(LinearGradient(colors: [Desk.accent.opacity(0.35), Desk.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }.stroke(Desk.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(Desk.accent).frame(width: 5, height: 5).position(points[points.count - 1])
                }
            }
        }
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
