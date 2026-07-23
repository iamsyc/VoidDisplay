import SwiftUI
import VoidDisplayFoundation

package struct VirtualDisplayPhysicalConfigurationSection: View {
    @Binding private var screenDiagonal: Double
    @Binding private var selectedAspectRatio: AspectRatio

    private let physicalSizeText: String
    private let focusedField: FocusState<VirtualDisplayConfigurationFocusField?>.Binding
    private let onAspectRatioChange: () -> Void

    package init(
        screenDiagonal: Binding<Double>,
        selectedAspectRatio: Binding<AspectRatio>,
        physicalSizeText: String,
        focusedField: FocusState<VirtualDisplayConfigurationFocusField?>.Binding,
        onAspectRatioChange: @escaping () -> Void = {}
    ) {
        _screenDiagonal = screenDiagonal
        _selectedAspectRatio = selectedAspectRatio
        self.physicalSizeText = physicalSizeText
        self.focusedField = focusedField
        self.onAspectRatioChange = onAspectRatioChange
    }

    package var body: some View {
        Section {
            HStack {
                Text("Screen Size")
                Spacer()
                TextField("Screen Size", value: $screenDiagonal, format: .number.precision(.fractionLength(1)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused(focusedField, equals: .screenDiagonal)
                Text("inches")
            }

            Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio.rawValue).tag(ratio)
                }
            }
            .onChange(of: selectedAspectRatio) { _, _ in
                onAspectRatioChange()
            }

            HStack {
                Text("Physical Size")
                Spacer()
                Text(verbatim: physicalSizeText)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .aspectRatio(aspectPreviewRatio, contentMode: .fit)
                    .frame(height: 60)
                    .overlay {
                        Text(selectedAspectRatio.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                Spacer()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Physical Display")
        }
    }

    private var aspectPreviewRatio: CGFloat {
        let components = selectedAspectRatio.components
        return CGFloat(components.width / components.height)
    }
}
