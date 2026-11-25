import SwiftUI
import AppKit

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            .padding(.leading, 4).padding(.bottom, -10)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct RowDivider: View { var body: some View { Divider().padding(.leading, 16) } }

struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let label: (Double) -> String
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step).frame(width: 200)
            Text(label(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

struct SettingsIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        Image(systemName: pane.icon)
            .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}
