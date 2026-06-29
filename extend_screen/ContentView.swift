//
//  ContentView.swift
//  extend_screen
//
//  Created by linke on 2026/6/28.
//

import Combine
import SwiftUI

@MainActor
final class VirtualDisplayModel: ObservableObject {
    @Published var autoMode: Bool = true
    @Published var width: String = "800"
    @Published var height: String = "480"
    @Published var refreshRate: String = "60"
    @Published var hiDPI: Bool = false
    @Published var vendorID: String = "303A"
    @Published var productID: String = "2987"
    @Published var jpegQuality: String = "6"
    @Published var streamFPS: String = "15"
    @Published var status: String = "Idle"
    @Published var usbStatus: String = "USB disconnected"
    @Published var displayID: UInt32 = 0
    @Published var displaySummary: String = ""
    @Published var displayRunning: Bool = false
    @Published var usbConnected: Bool = false
    @Published var streaming: Bool = false

    private let controller = VirtualDisplayController()
    private let streamer = USBDisplayStreamer()
    private let autoVendorID: UInt16 = 0x303A
    private let autoProductIDs: [UInt16] = [0x2987, 0x2986]

    init() {
        status = "Waiting for ESP USB display"
    }

    var isRunning: Bool {
        displayRunning
    }

    var isUSBConnected: Bool {
        usbConnected
    }

    var isStreaming: Bool {
        streaming
    }

    func start() {
        let parsedWidth = UInt32(width) ?? 800
        let parsedHeight = UInt32(height) ?? 480
        let parsedRefreshRate = Double(refreshRate) ?? 60

        if controller.start(withWidth: parsedWidth, height: parsedHeight, refreshRate: parsedRefreshRate, hiDPI: hiDPI)
        {
            displayID = controller.displayID
            status = "Running: display ID \(displayID)"
        } else {
            status = controller.lastError ?? "Failed to create virtual display."
        }
        refreshDisplays()
        syncRuntimeState()
    }

    func tick() {
        if autoMode {
            runAutoStep()
        } else {
            refreshUSBStatus()
        }
    }

    func scanNow() {
        runAutoStep()
    }

    func stop() {
        autoMode = false
        stopDisplay()
    }

    func toggleDisplayFromDebug() {
        autoMode = false
        if controller.isRunning {
            stopDisplay()
        } else {
            start()
        }
    }

    func stopDisplay() {
        stopStreaming()
        controller.stop()
        displayID = 0
        status = "Display stopped"
        refreshDisplays()
        syncRuntimeState()
    }

    func refreshDisplays() {
        displaySummary = controller.currentDisplaySummary()
        syncRuntimeState()
    }

    func connectUSB() {
        let parsedVendorID = parseHexUInt16(vendorID, default: 0x303A)
        let parsedProductID = parseHexUInt16(productID, default: 0x2987)

        if streamer.connect(withVendorID: parsedVendorID, productID: parsedProductID) {
            applyDetectedUSBSettings()
            usbStatus = streamer.statusSummary
        } else {
            usbStatus = streamer.lastError ?? "Failed to connect USB device."
        }
        syncRuntimeState()
    }

    func disconnectUSB() {
        streamer.disconnect()
        refreshUSBStatus()
        syncRuntimeState()
    }

    func startStreaming() {
        let parsedWidth = UInt16(width) ?? 800
        let parsedHeight = UInt16(height) ?? 480
        let parsedQuality = UInt(jpegQuality) ?? 6
        let parsedFPS = UInt(streamFPS) ?? 15

        if streamer.startStreamingDisplay(
            displayID, width: parsedWidth, height: parsedHeight, jpegQuality: parsedQuality, fps: parsedFPS)
        {
            usbStatus = streamer.statusSummary
        } else {
            usbStatus = streamer.lastError ?? "Failed to start USB stream."
            if isScreenRecordingPermissionError(usbStatus) {
                autoMode = false
                status = "Grant Screen Recording permission, then quit and reopen the app."
            }
        }
        syncRuntimeState()
    }

    func stopStreaming() {
        streamer.stopStreaming()
        refreshUSBStatus()
        syncRuntimeState()
    }

    func refreshUSBStatus() {
        usbStatus = streamer.statusSummary
        syncRuntimeState()
    }

    private func parseHexUInt16(_ value: String, default defaultValue: UInt16) -> UInt16 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        return UInt16(normalized, radix: 16) ?? defaultValue
    }

    private func runAutoStep() {
        if shouldResetAfterUSBError() {
            streamer.disconnect()
            controller.stop()
            displayID = 0
            status = "Waiting for ESP USB display"
            syncRuntimeState()
        }

        if !streamer.isConnected {
            status = "Waiting for ESP USB display"
            for productID in autoProductIDs {
                if streamer.connect(withVendorID: autoVendorID, productID: productID) {
                    applyDetectedUSBSettings()
                    usbStatus = streamer.statusSummary
                    break
                }
            }
            refreshUSBStatus()
            return
        }

        applyDetectedUSBSettings()

        guard streamer.displayWidth > 0, streamer.displayHeight > 0 else {
            status = "USB connected, waiting for display descriptor"
            refreshUSBStatus()
            return
        }

        if !controller.isRunning {
            start()
            return
        }

        if !streamer.isStreaming {
            startStreaming()
            return
        }

        status = "Streaming: \(width)x\(height) @ \(streamFPS)fps"
        refreshUSBStatus()
    }

    private func syncRuntimeState() {
        displayRunning = controller.isRunning
        usbConnected = streamer.isConnected
        streaming = streamer.isStreaming
    }

    private func applyDetectedUSBSettings() {
        if streamer.connectedVendorID != 0 {
            vendorID = String(format: "%04X", streamer.connectedVendorID)
        }
        if streamer.connectedProductID != 0 {
            productID = String(format: "%04X", streamer.connectedProductID)
        }
        if streamer.displayWidth > 0 {
            width = "\(streamer.displayWidth)"
        }
        if streamer.displayHeight > 0 {
            height = "\(streamer.displayHeight)"
        }
        if streamer.displayJPEGQuality > 0 {
            jpegQuality = "\(streamer.displayJPEGQuality)"
        }
        if streamer.displayMaxFPS > 0 {
            streamFPS = "\(min(streamer.displayMaxFPS, 60))"
            refreshRate = "\(min(streamer.displayMaxFPS, 60))"
        }
    }

    private func shouldResetAfterUSBError() -> Bool {
        guard streamer.isConnected, let error = streamer.lastError else {
            return false
        }
        return error.contains("WritePipe")
            || error.contains("No Device")
            || error.contains("not responding")
            || error.contains("not open")
    }

    private func isScreenRecordingPermissionError(_ message: String) -> Bool {
        message.contains("Screen Recording permission")
    }
}

struct ContentView: View {
    @StateObject private var model = VirtualDisplayModel()
    @State private var debugExpanded = false
    private let statsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ESP USB Virtual Display")
                    .font(.title2.weight(.semibold))
                Text(model.status)
                    .foregroundStyle(model.isStreaming ? .green : .secondary)
            }

            HStack {
                Toggle("Auto", isOn: $model.autoMode)
                    .toggleStyle(.switch)

                Button("Scan Now") {
                    model.scanNow()
                }

                Button("Stop Extend") {
                    model.stop()
                }
                .disabled(!model.isRunning && !model.isUSBConnected)
            }

            Text(model.usbStatus)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            DisclosureGroup("Debug", isExpanded: $debugExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Width")
                            TextField("800", text: $model.width)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("Height")
                            TextField("480", text: $model.height)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("Refresh")
                            TextField("60", text: $model.refreshRate)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("VID")
                            TextField("303A", text: $model.vendorID)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("PID")
                            TextField("2987", text: $model.productID)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("JPEG")
                            TextField("6", text: $model.jpegQuality)
                                .frame(width: 90)
                        }
                        GridRow {
                            Text("FPS")
                            TextField("15", text: $model.streamFPS)
                                .frame(width: 90)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Toggle("HiDPI", isOn: $model.hiDPI)

                    HStack {
                        Button(model.isRunning ? "Stop Display" : "Start Display") {
                            model.toggleDisplayFromDebug()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Refresh Displays") {
                            model.refreshDisplays()
                        }

                        Button("Connect USB") {
                            model.connectUSB()
                        }
                        .disabled(model.isUSBConnected)

                        Button("Disconnect") {
                            model.disconnectUSB()
                        }
                        .disabled(!model.isUSBConnected)

                        Button("Start Stream") {
                            model.startStreaming()
                        }
                        .disabled(!model.isRunning || !model.isUSBConnected || model.isStreaming)

                        Button("Stop Stream") {
                            model.stopStreaming()
                        }
                        .disabled(!model.isStreaming)
                    }
                }
                .padding(.top, 10)
            }

            Text(model.displaySummary.isEmpty ? "Display list has not been refreshed." : model.displaySummary)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            model.tick()
        }
        .onReceive(statsTimer) { _ in
            model.tick()
        }
    }
}
