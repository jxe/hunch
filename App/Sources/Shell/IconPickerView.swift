#if os(iOS)
import SwiftUI
import UIKit
import Editor

private struct IconOption: Identifiable {
    let id: String?
    let label: String
    let assetName: String
}

private let iconOptions: [IconOption] = [
    .init(id: nil, label: "Man", assetName: "HunchbackMan"),
    .init(id: "AppIcon-Woman", label: "Woman", assetName: "HunchbackWoman"),
]

struct IconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current: String? = UIApplication.shared.alternateIconName

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Pick your hunchback.")
                    .font(HunchStyle.body(size: 14))
                    .foregroundStyle(HunchStyle.mutedForeground)
                HStack(spacing: 20) {
                    ForEach(iconOptions) { option in
                        IconTile(
                            option: option,
                            isSelected: option.id == current,
                            onTap: { select(option) }
                        )
                    }
                }
                Spacer()
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HunchStyle.background)
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func select(_ option: IconOption) {
        guard option.id != current else { return }
        let previous = current
        current = option.id
        UIApplication.shared.setAlternateIconName(option.id) { error in
            if error != nil {
                Task { @MainActor in current = previous }
            }
        }
    }
}

private struct IconTile: View {
    let option: IconOption
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    iconImage
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(
                                    isSelected ? HunchStyle.linkForeground : HunchStyle.mutedForeground.opacity(0.25),
                                    lineWidth: isSelected ? 3 : 1
                                )
                        )
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, HunchStyle.linkForeground)
                            .offset(x: 6, y: 6)
                    }
                }
                Text(option.label)
                    .font(HunchStyle.body(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(HunchStyle.foreground)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var iconImage: Image {
        if let ui = UIImage(named: option.assetName) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "app.dashed")
    }
}
#endif
