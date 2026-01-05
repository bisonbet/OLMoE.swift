//
//  ModelDownloadView.swift
//  OLMoE.swift
//
//  Created by Luca Soldaini on 2024-09-19.
//


import SwiftUI
import Combine
import Network

func formatSize(_ size: Int64) -> String {
    let sizeInGB = Double(size) / 1_000_000_000.0
    return String(format: "%.2f GB", sizeInGB)
}

class BackgroundDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadManager()

    @Published var downloadProgress: Float = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var isModelReady = false
    @Published var downloadedSize: Int64 = 0
    @Published var totalSize: Int64 = 0
    @Published var selectedModel: ModelInfo = AppConstants.Models.defaultModel
    @Published var currentlyDownloadingModel: ModelInfo?

    private var networkMonitor: NWPathMonitor?
    private var backgroundSession: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var lastUpdateTime: Date = Date()
    private var hasCheckedDiskSpace = false
    private let updateInterval: TimeInterval = 0.5 // Update UI every 0.5 seconds
    private var lastDispatchedBytesWritten: Int64 = 0

    private override init() {
        super.init()
        // Use regular foreground session for faster downloads
        // Background sessions let the system throttle which causes slow, spiky downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 // 1 hour for large downloads
        config.waitsForConnectivity = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        startNetworkMonitoring()
    }

    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                if path.status == .unsatisfied {
                    self.downloadError = "Connection lost. Please check your internet connection."
                    self.isDownloading = false
                    self.hasCheckedDiskSpace = false
                    self.isModelReady = false
                    self.lastDispatchedBytesWritten = 0
                    self.downloadTask?.cancel()
                }
            }
        }

        let queue = DispatchQueue(label: "NetworkMonitor")
        networkMonitor?.start(queue: queue)
    }

    /// Starts the download process for a specific model.
    /// - Parameter model: The model to download. If nil, downloads the selected model.
    func startDownload(for model: ModelInfo? = nil) {
        if networkMonitor?.currentPath.status == .unsatisfied {
            DispatchQueue.main.async {
                self.downloadError = "No network connection available. Please check your internet connection."
            }
            return
        }

        let modelToDownload = model ?? selectedModel
        guard let url = URL(string: modelToDownload.downloadURL) else {
            DispatchQueue.main.async {
                self.downloadError = "Invalid download URL for \(modelToDownload.displayName)"
            }
            return
        }

        print("[Download] Starting download for \(modelToDownload.displayName)")
        print("[Download] URL: \(url)")

        // Cancel any existing download task
        downloadTask?.cancel()

        DispatchQueue.main.async {
            self.currentlyDownloadingModel = modelToDownload
            self.isDownloading = true
            self.downloadError = nil
            self.downloadedSize = 0
            self.totalSize = 0
            self.lastDispatchedBytesWritten = 0
            self.hasCheckedDiskSpace = false
        }

        // Create a URL request with proper headers
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        downloadTask = backgroundSession.downloadTask(with: request)
        downloadTask?.resume()

        print("[Download] Task started, state: \(downloadTask?.state.rawValue ?? -1)")
    }

    /// Legacy method for backward compatibility
    func startDownload() {
        startDownload(for: nil)
    }

    /// Handles the completion of the download task.
    /// - Parameters:
    ///   - session: The URL session that completed the task.
    ///   - downloadTask: The download task that completed.
    ///   - location: The temporary location of the downloaded file.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let model = currentlyDownloadingModel ?? selectedModel
        let destination = model.fileURL

        print("[Download] Finished! Temp location: \(location)")
        print("[Download] Moving to: \(destination)")

        do {
            // Ensure models directory exists
            try FileManager.default.createDirectory(at: URL.modelsDirectory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            // Verify the file was saved correctly
            let fileSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0
            print("[Download] File saved successfully. Size: \(formatSize(fileSize))")

            DispatchQueue.main.async {
                self.selectedModel = model
                self.isModelReady = true
                self.isDownloading = false
                self.currentlyDownloadingModel = nil
            }
        } catch {
            print("[Download] Failed to save file: \(error)")
            DispatchQueue.main.async {
                self.downloadError = "Failed to save file: \(error.localizedDescription)"
                self.isDownloading = false
                self.currentlyDownloadingModel = nil
            }
        }
    }

    /// Handles errors that occur during the download task.
    /// - Parameters:
    ///   - session: The URL session that completed the task.
    ///   - task: The task that completed.
    ///   - error: The error that occurred, if any.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("[Download] Task completed. Error: \(error?.localizedDescription ?? "none")")
        print("[Download] Task state: \(task.state.rawValue), Response: \(String(describing: task.response))")

        if let httpResponse = task.response as? HTTPURLResponse {
            print("[Download] HTTP Status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                DispatchQueue.main.async {
                    self.downloadError = "Server returned status \(httpResponse.statusCode)"
                    self.isDownloading = false
                    self.hasCheckedDiskSpace = false
                    self.currentlyDownloadingModel = nil
                }
                return
            }
        }

        DispatchQueue.main.async {
            if let error = error {
                if self.downloadError == nil {
                    self.downloadError = "Download failed: \(error.localizedDescription)"
                }
                self.isDownloading = false
                self.hasCheckedDiskSpace = false
                self.currentlyDownloadingModel = nil
            }
        }
    }

    /// Handles HTTP redirects
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        print("[Download] Redirect to: \(request.url?.absoluteString ?? "unknown")")
        // Allow the redirect
        completionHandler(request)
    }

    /// Handles authentication challenges (e.g., from CDN)
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        print("[Download] Auth challenge: \(challenge.protectionSpace.authenticationMethod)")
        completionHandler(.performDefaultHandling, nil)
    }

    /// Updates the download progress and checks for disk space during the download.
    /// - Parameters:
    ///   - session: The URL session managing the download.
    ///   - downloadTask: The download task that is writing data.
    ///   - bytesWritten: The number of bytes written in this update.
    ///   - totalBytesWritten: The total number of bytes written so far.
    ///   - totalBytesExpectedToWrite: The total number of bytes expected to be written.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if !hasCheckedDiskSpace {
            hasCheckedDiskSpace = true
            if !hasEnoughDiskSpace(requiredSpace: totalBytesExpectedToWrite) {
                DispatchQueue.main.async {
                    self.downloadError = "Not enough disk space available.\nNeed \(formatSize(totalBytesExpectedToWrite)) free."
                }
                downloadTask.cancel()
                return
            }
        }

        let currentTime = Date()
        // Update lastUpdateTime immediately to prevent race condition
        guard currentTime.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }
        lastUpdateTime = currentTime

        // Check if this update has newer data than what we've already dispatched
        guard totalBytesWritten > lastDispatchedBytesWritten else { return }
        lastDispatchedBytesWritten = totalBytesWritten

        DispatchQueue.main.async {
            self.downloadProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
            self.downloadedSize = totalBytesWritten
            self.totalSize = totalBytesExpectedToWrite
        }
    }

    /// Deletes the downloaded model file for a specific model.
    /// - Parameter model: The model to delete. If nil, deletes the selected model.
    func flushModel(_ model: ModelInfo? = nil) {
        let modelToFlush = model ?? selectedModel
        do {
            if FileManager.default.fileExists(atPath: modelToFlush.fileURL.path) {
                try FileManager.default.removeItem(at: modelToFlush.fileURL)
            }
            // Check if any model is still available
            let anyModelReady = AppConstants.Models.all.contains { $0.isDownloaded }
            if !anyModelReady {
                isModelReady = false
            } else if modelToFlush.id == selectedModel.id {
                // If we deleted the selected model, switch to another available one
                if let availableModel = AppConstants.Models.all.first(where: { $0.isDownloaded }) {
                    selectedModel = availableModel
                } else {
                    isModelReady = false
                }
            }
        } catch {
            downloadError = "Failed to flush model: \(error.localizedDescription)"
        }
    }

    /// Selects a model to use (must be already downloaded)
    /// - Parameter model: The model to select
    func selectModel(_ model: ModelInfo) {
        guard model.isDownloaded else { return }
        selectedModel = model
        isModelReady = true
    }

    /// Checks which models are downloaded and updates state accordingly
    func refreshModelStatus() {
        // Check if selected model is still available
        if selectedModel.isDownloaded {
            isModelReady = true
        } else if let availableModel = AppConstants.Models.all.first(where: { $0.isDownloaded }) {
            selectedModel = availableModel
            isModelReady = true
        } else {
            isModelReady = false
        }
    }

    /// Checks if there is enough disk space available for the required space.
    /// - Parameter requiredSpace: The amount of space required in bytes.
    /// - Returns: A boolean indicating whether there is enough disk space.
    private func hasEnoughDiskSpace(requiredSpace: Int64) -> Bool {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let availableCapacity = values.volumeAvailableCapacityForImportantUsage {
                return availableCapacity > requiredSpace
            }
        } catch {
            print("Error retrieving available disk space: \(error.localizedDescription)")
        }
        return false
    }
}

/// A row view for displaying a single model option
struct ModelRowView: View {
    let model: ModelInfo
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Float
    let onDownload: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.telegraf(.medium, size: 20))
                        .foregroundColor(Color("TextColor"))

                    Text(model.description)
                        .font(.body(.regular))
                        .foregroundColor(Color("TextColor").opacity(0.7))
                        .lineLimit(2)
                }

                Spacer()

                if model.isDownloaded {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color("AccentColor"))
                            .font(.title2)
                    } else {
                        Button(action: onSelect) {
                            Text("Use")
                                .font(.body())
                        }
                        .buttonStyle(.PrimaryButton)
                    }
                }
            }

            HStack {
                Text(model.downloadSize)
                    .font(.caption)
                    .foregroundColor(Color("TextColor").opacity(0.6))

                Spacer()

                if isDownloading {
                    ProgressView(value: downloadProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 100)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(Color("TextColor"))
                } else if model.isDownloaded {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(action: onDownload) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download")
                        }
                        .font(.body())
                    }
                    .buttonStyle(.PrimaryButton)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color("AccentColor").opacity(0.1) : Color("BackgroundColor"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color("AccentColor") : Color("DividerTeal"), lineWidth: isSelected ? 2 : 1)
                )
        )
    }
}

/// A view that displays the model selection and download interface.
struct ModelDownloadView: View {
    @StateObject private var downloadManager = BackgroundDownloadManager.shared
    @State private var modelToDownload: ModelInfo?
    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false

    public var body: some View {
        ZStack {
            Color("BackgroundColor")
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 24) {
                Text("Select a Model")
                    .font(.telegraf(.medium, size: 32))
                    .foregroundColor(Color("TextColor"))

                Text("Choose which AI model to use. Models are downloaded once and run locally on your device.")
                    .multilineTextAlignment(.center)
                    .font(.body(.regular))
                    .foregroundColor(Color("TextColor").opacity(0.8))
                    .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(AppConstants.Models.all) { model in
                            ModelRowView(
                                model: model,
                                isSelected: downloadManager.selectedModel.id == model.id && model.isDownloaded,
                                isDownloading: downloadManager.isDownloading && downloadManager.currentlyDownloadingModel?.id == model.id,
                                downloadProgress: downloadManager.downloadProgress,
                                onDownload: {
                                    modelToDownload = model
                                },
                                onSelect: {
                                    downloadManager.selectModel(model)
                                },
                                onDelete: {
                                    modelToDelete = model
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                if let error = downloadManager.downloadError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding()
                }

                Spacer()

                Ai2LogoView(applyMacCatalystPadding: true)
            }
            .padding(.top, 40)
        }
        .sheet(item: $modelToDownload) { model in
            SheetWrapper {
                HStack {
                    Spacer()
                    CloseButton(action: { modelToDownload = nil })
                }
                Spacer()
                VStack(spacing: 20) {
                    Text("Download \(model.displayName)")
                        .font(.title())

                    Text("This model requires \(model.downloadSize) of storage space. Would you like to proceed with the download?")
                        .multilineTextAlignment(.center)
                        .font(.body())

                    VStack(spacing: 12) {
                        Button {
                            let modelToStart = model
                            modelToDownload = nil
                            downloadManager.startDownload(for: modelToStart)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Start Download")
                            }
                        }
                        .buttonStyle(.PrimaryButton)
                    }
                }
                .padding()
                Spacer()
            }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    downloadManager.flushModel(model)
                }
                modelToDelete = nil
            }
        } message: {
            if let model = modelToDelete {
                Text("Are you sure you want to delete \(model.displayName)? You can download it again later.")
            }
        }
        .onAppear {
            downloadManager.refreshModelStatus()
        }
    }
}

#Preview("ModelDownloadView") {
    ModelDownloadView()
        .preferredColorScheme(.dark)
        .padding()
        .background(Color("BackgroundColor"))
}
