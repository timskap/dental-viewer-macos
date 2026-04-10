import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: VolumeStore

    @State private var yaw: Float = 0.6
    @State private var pitch: Float = 0.25
    @State private var distance: Float = 2.6

    var body: some View {
        VStack(spacing: 0) {
            Toolbar()
            Divider()

            HStack(spacing: 0) {
                Volume3DPane(yaw: $yaw, pitch: $pitch, distance: $distance)
                    .frame(minWidth: 480)

                Divider()

                VStack(spacing: 0) {
                    MPRSliceView(plane: .axial)
                    Divider()
                    MPRSliceView(plane: .coronal)
                    Divider()
                    MPRSliceView(plane: .sagittal)
                }
                .frame(width: 320)
                .background(Color(nsColor: .windowBackgroundColor))
            }

            Divider()
            StatusBar()
        }
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @EnvironmentObject var store: VolumeStore

    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.openFolder()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 22)

            Picker("Mode", selection: $store.renderMode) {
                Text("MIP").tag(RenderMode.mip)
                Text("Composite").tag(RenderMode.composite)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(value: $store.windowCenter, in: 0...1)
                    .frame(width: 130)
                Text("Center")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                Slider(value: $store.windowWidth, in: 0.05...1)
                    .frame(width: 130)
                Text("Width")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject var store: VolumeStore

    var body: some View {
        HStack(spacing: 8) {
            if store.loading {
                ProgressView().controlSize(.small)
            }
            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("Drag to rotate · Scroll to zoom")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 3D pane (Metal view + clip-plane controls overlay)

private struct Volume3DPane: View {
    @EnvironmentObject var store: VolumeStore
    @Binding var yaw: Float
    @Binding var pitch: Float
    @Binding var distance: Float

    @State private var dragLast: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VolumeMetalView(yaw: $yaw, pitch: $pitch, distance: $distance)
                .background(Color.black)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragLast = .zero
                            }
                            let dx = Float(value.translation.width  - dragLast.width)
                            let dy = Float(value.translation.height - dragLast.height)
                            yaw  -= dx * 0.006
                            pitch += dy * 0.006
                            pitch = max(-1.4, min(1.4, pitch))
                            dragLast = value.translation
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragLast = .zero
                        }
                )

            if store.volume == nil {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Open a DICOM folder to begin")
                        .foregroundStyle(.secondary)
                    Text("File ▸ Open DICOM Folder…    (⌘O)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }

            ClipControlsOverlay()
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
        }
    }
}

private struct ClipControlsOverlay: View {
    @EnvironmentObject var store: VolumeStore

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $store.clipEnabled) {
                Label("Clip", systemImage: "scissors")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.clipEnabled {
                Picker("Axis", selection: $store.clipAxis) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .labelsHidden()

                Slider(value: $store.clipPosition, in: 0...1)
                    .frame(width: 220)
                    .controlSize(.small)

                Toggle("Flip", isOn: $store.clipFlip)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .font(.caption)
    }
}
