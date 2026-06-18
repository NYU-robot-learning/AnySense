//
//  accountView.swift
//  Anysense
//
//  Created by Michael on 2024/5/27.
//

import SwiftUI
import CoreBluetooth
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView : View{
    @EnvironmentObject var appStatus: AppInformation
    @ObservedObject var arViewModel: ARViewModel
    let modelManager: ModelManager
    
    // File picker state
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    // Track current frequency for UI updates
    @State private var currentFrequencyIndex: Int = 1
    
    // Map available inference frequencies to picker choices
    private let inferenceOptions: [MLInferenceManager.InferenceFrequency] = MLInferenceManager.InferenceFrequency.allCases
    
    // Helper function for short display names
    private func shortDisplayName(for frequency: MLInferenceManager.InferenceFrequency) -> String {
        switch frequency {
        case .high: return "30 Hz"
        case .medium: return "1 Hz"
        case .low: return "0.1 Hz"
        case .minute: return "0.017 Hz"
        }
    }
    
    var body : some View{
        ZStack{
            Color.customizedBackground
                            .ignoresSafeArea()
            Form {
                Section(header: Text("GENERAL")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            // Title and caption
                            Text("Live RGBD Streaming")
                                .font(.body) // Regular font
                                .foregroundColor(.primary)
                            Text("Stream to your computer")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        let binding = Binding<StreamingMode>(
                            get: { appStatus.rgbdVideoStreaming },
                            set: { newValue in
                                appStatus.rgbdVideoStreaming = newValue
                            }
                        )
                        Picker("Streaming Options", selection: binding) { //
                            Text("USB").tag(StreamingMode.usb)
                            Text("Off").tag(StreamingMode.off)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 125) // Adjust width for the picker
                    }
                    .padding(.vertical, 5)
                    .padding(.vertical, 5)
                    HStack{
                        Toggle("Audio recording enabled", isOn: Binding(
                            get: { appStatus.ifAudioRecordingEnabled },
                            set: { enabled in
                                appStatus.ifAudioRecordingEnabled = enabled
                                arViewModel.ifAudioEnable = enabled
                            }
                        ))
                    }
                    HStack{
                            Text("Buttons haptic feedback")
                            .font(.body)
                            .foregroundColor(.primary)
    //                        .padding(.leading, 20)
                            Spacer()
                            Picker("", selection: $appStatus.hapticFeedbackLevel) {
                                Text("medium").tag(UIImpactFeedbackGenerator.FeedbackStyle.medium)
                                Text("heavy").tag(UIImpactFeedbackGenerator.FeedbackStyle.heavy)
                                Text("light").tag(UIImpactFeedbackGenerator.FeedbackStyle.light)
                            }
                            .pickerStyle(MenuPickerStyle()) // Dropdown style
                            .frame(width: 110)
    //                    .padding(.leading, 75)
                    }
                    .padding(.vertical, 5)
                    HStack{
                        VStack(alignment: .leading, spacing: 8){
                            Picker("Grid projection enabled", selection: $appStatus.gridProjectionTrigger){
                                Text("3x3").tag(GridMode._3x3)
                                Text("5x5").tag(GridMode._5x5)
                                Text("off").tag(GridMode.off)
                            }
                            .pickerStyle(MenuPickerStyle())
                            Text("Project grid lines to your camera")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }
                }
                
                // MARK: - Model Management Section
                Section(header: Text("MODEL MANAGEMENT")) {
                    // Upload Model Button
                    Button("Upload Model") {
                        showingFilePicker = true
                    }
                    .foregroundColor(.blue)
                    .sheet(isPresented: $showingFilePicker) {
                        ModelImporter(onPickDocument: handleModelUpload)
                    }

                    // Compilation Progress
                    if modelManager.isCompiling {
                        HStack {
                            Text("Compiling model...")
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                ProgressView(value: modelManager.compilationProgress)
                                    .frame(width: 100)
                                Text("\(Int(modelManager.compilationProgress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 5)
                    }

                    // Model Selection (when compiled models available)
                    if !modelManager.compiledModels.isEmpty {
                        Picker("Select Model", selection: Binding<UUID?>(
                            get: {
                                let activeID = modelManager.activeModelID
                                // print("DEBUG: Picker get - activeModelID: \(String(describing: activeID))")
                                return activeID
                            },
                            set: { newValue in
                                // print("DEBUG: Picker set - newValue: \(String(describing: newValue))")
                                if let newValue = newValue {
                                    // Force immediate UI update
                                    DispatchQueue.main.async {
                                        modelManager.setActiveModel(id: newValue)
                                    }
                                }
                            }
                        )) {
                            ForEach(modelManager.compiledModels) { model in
                                Text(model.displayName).tag(model.id as UUID?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .padding(.vertical, 5)
                        .id(modelManager.activeModelID?.uuidString ?? "none") // Force refresh when activeModel changes
                    }
                }

                // MARK: - Inference Settings Section
                Section(header: Text("INFERENCE SETTINGS")) {
                    // Inference is tab-scoped (enabled automatically in the Inference tab)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inference runs automatically in the Inference tab")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 5)

                    // Inference Frequency Slider
                    if let mlManager = arViewModel.mlManager {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Inference Frequency")
                                .font(.body)
                                .foregroundColor(.primary)

                            let sliderBinding = Binding<Double>(
                                get: {
                                    Double(currentFrequencyIndex)
                                },
                                set: { newValue in
                                    let index = Int(newValue.rounded())
                                    if index >= 0 && index < inferenceOptions.count {
                                        currentFrequencyIndex = index
                                        mlManager.setInferenceFrequency(inferenceOptions[index])
                                    }
                                }
                            )

                            Slider(value: sliderBinding,
                                   in: 0...Double(inferenceOptions.count - 1),
                                   step: 1)

                            HStack {
                                ForEach(0..<inferenceOptions.count, id: \.self) { index in
                                    let option = inferenceOptions[index]
                                    let isSelected = index == currentFrequencyIndex

                                    Text(shortDisplayName(for: option))
                                        .font(.caption2)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .foregroundColor(isSelected ? .blue : .gray)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        .onAppear {
                            // Initialize with current frequency
                            currentFrequencyIndex = inferenceOptions.firstIndex(of: mlManager.inferenceFrequency) ?? 1
                        }
                    }

                    // Gripper Overlay Settings
                    HStack {
                        Text("Show Gripper Overlay")
                            .font(.body)
                            .foregroundColor(.primary)
                        Spacer()
                        Toggle("", isOn: $appStatus.showGripperOverlay)
                    }
                    .padding(.vertical, 5)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Include in Model Input")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Feed gripper overlay to ML model")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $appStatus.enableGripperOverlayInModel)
                    }
                    .padding(.vertical, 5)

                }
            }
            .scrollContentBackground(.hidden)
        }
        .alert("Model Upload", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Model Upload Handling
    private func handleModelUpload(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    try await modelManager.uploadAndCompileModel(from: url)
                    
                    DispatchQueue.main.async {
                        alertMessage = "Model uploaded and compiled successfully!"
                        showingAlert = true
                    }
                } catch {
                    DispatchQueue.main.async {
                        alertMessage = "Failed to upload model: \(error.localizedDescription)"
                        showingAlert = true
                    }
                }
            }
            
        case .failure(let error):
            alertMessage = "Failed to select file: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
}

enum StreamingMode: String {
    case off = "Off"
    case usb = "USB"
}

enum GridMode: Int {
    case off = 0
    case _3x3 = 3
    case _5x5 = 5
}

// MARK: - Model Importer
struct ModelImporter: UIViewControllerRepresentable {
    let onPickDocument: (Result<URL, Error>) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Prefer system-declared UTIs; fall back to filename extensions for safety
        let mlmodel = UTType(importedAs: "com.apple.coreml.model")
        let mlpackage = UTType(importedAs: "com.apple.coreml.modelpackage")
        // Compiled model UTI name varies by SDK; use a broad fallback as well
        let mlmodelc = UTType(importedAs: "com.apple.coreml.compiled-model")
        
        var allowedTypes: [UTType] = [mlmodel, mlpackage, mlmodelc, .package, .data, .item]
        // Add filename-extension fallbacks to catch older devices
        if let byExt1 = UTType(filenameExtension: "mlmodel") { allowedTypes.append(byExt1) }
        if let byExt2 = UTType(filenameExtension: "mlmodelc") { allowedTypes.append(byExt2) }
        if let byExt3 = UTType(filenameExtension: "mlpackage") { allowedTypes.append(byExt3) }
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ModelImporter
        
        init(_ parent: ModelImporter) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPickDocument(.success(url))
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled - no action needed
        }
    }
}

#Preview {
    SettingsView(arViewModel: ARViewModel(), modelManager: ModelManager())
        .environmentObject(AppInformation())
}
