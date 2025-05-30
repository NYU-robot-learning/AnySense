//
//  accountView.swift
//  Anysense
//
//  Created by Michael on 2024/5/27.
//

import SwiftUI
import CoreBluetooth
import AVFoundation

struct SettingsView : View{
    @EnvironmentObject var appStatus: AppInformation
    
    let frequencyOptions = ["0.1", "0.05", "0.033", "0.02", "0.017", "0.01"] // Frequency options
    
    var body : some View{
        ZStack{
            Color.customizedBackground
                            .ignoresSafeArea()
            Form{
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
                        Toggle("Audio recording enabled", isOn: $appStatus.ifAudioRecordingEnabled)
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
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            // Title and caption
                            Text("ResNet Classification")
                                .font(.body) // Regular font
                                .foregroundColor(.primary)
                            Text("Inferencing on-device")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $appStatus.mlInferenceEnabled)
                    }
                    .padding(.vertical, 5)
                    
                }
//                Section(header: Text("INFO")) {
//                    NavigationLink {
//                        InstructionView()
//                    } label: {
//                        HStack {
//                            Text("How to use?")
//                                .font(.body)
//                                .foregroundColor(.black)
//                            Spacer()
//                        }
//                    }
//                    NavigationLink {
//                        fileMarkdownView()
//                    } label: {
//                        HStack {
//                            Text("About")
//                                .font(.body)
//                                .foregroundColor(.black)
//                            Spacer()
//                        }
//                    }
//                }
            }
            .scrollContentBackground(.hidden)
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

#Preview {
    SettingsView()
        .environmentObject(AppInformation())
}
