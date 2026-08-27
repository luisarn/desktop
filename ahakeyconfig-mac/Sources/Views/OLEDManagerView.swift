import SwiftUI
import UniformTypeIdentifiers

struct OLEDManagerView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    @State private var selectedImage: NSImage?
    @State private var selectedGIFURL: URL?
    @State private var fps: Int = 30
    @State private var frameCount: Int = 0

    var body: some View {
        Form {
            Section("Animation Manager") {
                // 预览区
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                        .frame(height: 160)

                    if let image = selectedImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 140)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No Image")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Add Image") {
                        selectImage()
                    }
                    .buttonStyle(.bordered)

                    Button("Add GIF") {
                        selectGIF()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Clear") {
                        selectedImage = nil
                        selectedGIFURL = nil
                        frameCount = 0
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                if frameCount > 0 {
                    HStack {
                        Text("FPS:")
                        Stepper("\(fps)", value: $fps, in: 1...30)
                            .frame(width: 100)
                        Spacer()
                        Text("\(frameCount) frames")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if bleManager.isConnected {
                Section {
                    Button("Upload to Device") {
                        // TODO: 通过 BLE 0x7343 分包上传图片/GIF 数据
                        // OLED 分辨率和图片格式待逆向确认
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImage == nil && selectedGIFURL == nil)
                }
            } else {
                Section {
                    Text("Please connect an AhaKey device first")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }

    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedImage = NSImage(contentsOf: url)
            selectedGIFURL = nil
            frameCount = 0
        }
    }

    private func selectGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gif")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: url)
            } catch {
                NSSound.beep()
                return
            }
            selectedGIFURL = url
            selectedImage = NSImage(contentsOf: url)
            // GIF 帧数估算
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                frameCount = CGImageSourceGetCount(source)
            }
        }
    }
}
