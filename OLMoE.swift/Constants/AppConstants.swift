import Foundation

/// Represents a downloadable model with its configuration
struct ModelInfo: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let description: String
    let filename: String
    let downloadURL: String
    let downloadSize: String
    let templateType: TemplateType

    /// The template types supported by the app
    enum TemplateType: String, Codable {
        case olmoe
        case phi3
    }

    /// Returns the URL where the model file should be stored
    var fileURL: URL {
        URL.modelsDirectory.appendingPathComponent(filename).appendingPathExtension("gguf")
    }

    /// Checks if this model is already downloaded
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

enum AppConstants {
    /// Available models for download and use
    enum Models {
        /// OLMoE-1B-7B (Mixture of Experts) - General purpose model from AI2
        /// Using i1 (importance matrix) quantization for better quality
        static let olmoe = ModelInfo(
            id: "olmoe",
            displayName: "OLMoE",
            description: "General-purpose language model with Mixture of Experts architecture from AI2",
            filename: "OLMoE-1B-7B-0125-Instruct.i1-Q4_K_M",
            downloadURL: "https://huggingface.co/mradermacher/OLMoE-1B-7B-0125-Instruct-i1-GGUF/resolve/main/OLMoE-1B-7B-0125-Instruct.i1-Q4_K_M.gguf?download=true",
            downloadSize: "4.21 GB",
            templateType: .olmoe
        )

        /// MediPhi (Medical domain) - Specialized for medical queries
        /// Using i1 (importance matrix) quantization for better quality
        static let mediPhi = ModelInfo(
            id: "mediphi",
            displayName: "MediPhi",
            description: "Medical domain specialized model based on Phi-3 architecture",
            filename: "MediPhi.i1-Q4_K_M",
            downloadURL: "https://huggingface.co/mradermacher/MediPhi-i1-GGUF/resolve/main/MediPhi.i1-Q4_K_M.gguf?download=true",
            downloadSize: "2.39 GB",
            templateType: .phi3
        )

        /// All available models
        static let all: [ModelInfo] = [olmoe, mediPhi]

        /// Default model to use
        static let defaultModel = olmoe
    }

    /// Legacy accessors for backward compatibility
    enum Model {
        static let filename = "OLMoE-1B-7B-0125-Instruct.i1-Q4_K_M"
        static let downloadURL = Models.olmoe.downloadURL
        static let downloadSize = Models.olmoe.downloadSize
        static let playgroundURL = "https://playground.allenai.org/?model=olmoe-0125"
    }
}