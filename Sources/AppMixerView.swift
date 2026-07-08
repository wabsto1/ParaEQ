import AppKit
import SwiftUI

/// Collapsible per-app volume mixer section. Rows are leaf views so playback
/// -state changes re-render one row, not the panel (perf rule: no engine/HAL
/// state read in container bodies).
struct AppMixerView: View {
    @Bindable var mixer: AppMixer
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("App Mixer")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !expanded {
                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .helpHint("Per-app volume: adjust or mute individual applications")

            if expanded {
                if mixer.displayApps.isEmpty {
                    Text("No apps are playing audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(mixer.displayApps) { app in
                            AppMixerRow(mixer: mixer, app: app)
                        }
                        if mixer.slotsFull {
                            Text("Mixer limit reached (16 adjusted apps)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var summaryText: String {
        let adjusted = mixer.settings.values.filter { !$0.isNeutral }.count
        let playing = mixer.directory?.apps.filter(\.isPlaying).count ?? 0
        if adjusted > 0 { return "\(adjusted) adjusted" }
        return playing > 0 ? "\(playing) playing" : ""
    }
}

/// One app row — a leaf view: reads only this app's setting.
private struct AppMixerRow: View {
    let mixer: AppMixer
    let app: AudioApp

    var body: some View {
        let setting = mixer.setting(for: app.bundleID)
        HStack(spacing: 8) {
            appIcon
                .frame(width: 18, height: 18)
                .opacity(app.isPlaying ? 1 : 0.5)
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(app.isPlaying ? .primary : .secondary)
            Slider(
                value: Binding(
                    get: { setting.gainDB },
                    set: { v in
                        // Snap sub-dB residue to true 0 since readout rounds to whole dB.
                        // Without this, the exception never reaches neutral/grace at zero.
                        let snapped = abs(v) < 0.5 ? 0 : v
                        mixer.setGain(snapped, for: app.bundleID)
                    }),
                in: -60...6)
            .controlSize(.mini)
            .disabled(setting.muted)
            Text(gainLabel(setting))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Button {
                mixer.setMuted(!setting.muted, for: app.bundleID)
            } label: {
                Image(systemName: setting.muted
                    ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(setting.muted ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .helpHint(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            if !setting.isNeutral || !app.isPlaying {
                Button {
                    mixer.reset(app.bundleID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .helpHint("Reset \(app.name) to normal volume")
            }
        }
        .padding(.vertical, 1)
    }

    private var appIcon: Image {
        if let nsApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleID).first,
           let icon = nsApp.icon {
            return Image(nsImage: icon)
        }
        return Image(systemName: "app.dashed")
    }

    private func gainLabel(_ s: AppMixerSetting) -> String {
        if s.muted { return "muted" }
        if s.gainDB <= -59.5 { return "-∞" }
        return String(format: "%+.0f dB", s.gainDB)
    }
}
