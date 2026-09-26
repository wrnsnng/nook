@preconcurrency import CoreML
import FluidAudio
import Foundation

/// One stretch of time in which a single separated voice was speaking.
struct SpeakerTurn: Codable, Hashable, Sendable {
    /// Seconds from the start of the diarized audio.
    let start: TimeInterval
    let end: TimeInterval
    /// 0-based. Speakers are numbered in the order they are first heard, so
    /// the same recording always yields the same numbers.
    let speaker: Int
}

enum SpeakerDiarizationError: LocalizedError, Equatable {
    /// The bundled models are absent or cannot be loaded. The build refuses to
    /// produce an app without them, so this means the bundle was damaged.
    case modelsMissing
    /// The audio file cannot be decoded or holds no audio.
    case unreadableAudio
    /// The separation engine failed for another reason.
    case failed

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            "Speaker separation is not available in this copy of Nook. Reinstall Nook to restore it."
        case .unreadableAudio:
            "Nook could not read this recording to separate speakers."
        case .failed:
            "Nook could not separate the speakers in this recording."
        }
    }
}

/// Separates the voices in a recording on this Mac, using FluidAudio's offline
/// pipeline (pyannote Community-1 segmentation, WeSpeaker embeddings and VBx
/// clustering) on Core ML models bundled inside the app.
///
/// Nothing here can reach the network. The models are loaded directly from
/// the app bundle with `MLModel`, never through FluidAudio's model hub, and the
/// hub is switched to offline mode before FluidAudio is first used, so even a
/// code path we do not call would fail instead of downloading. Nothing is
/// persisted: converted audio is deleted as it is mapped, and speaker
/// embeddings live only for the duration of one call.
///
/// Stateless and `Sendable`. Each call loads the models and releases them on
/// return, so a menu-bar app does not keep them resident between meetings.
///
/// Cost, measured on an M4 Pro: 36 minutes of synthetic three-voice audio took
/// 12 s, and a one-minute file under a second including model loading. Peak
/// memory rose by about 450 MB and barely grew with length, because the audio
/// is memory-mapped (see `DiarizationAudio`) and the engine's working set is
/// per batch of windows. Callers should run one call at a time for that
/// reason.
///
/// Cancellation surfaces as `CancellationError`, like everywhere else in
/// Nook, so the saved-note session can treat it the same way.
struct SpeakerDiarizationService: Sendable {
    static let modelsFolderName = "SpeakerDiarizationModels"

    /// The five files the offline pipeline needs, as laid out by
    /// Scripts/fetch-diarization-models.sh.
    enum ModelFile {
        static let segmentation = "Segmentation.mlmodelc"
        static let fbank = "FBank.mlmodelc"
        static let embedding = "Embedding.mlmodelc"
        static let pldaRho = "PldaRho.mlmodelc"
        static let pldaParameters = "plda-parameters.json"

        static let all = [segmentation, fbank, embedding, pldaRho, pldaParameters]
    }

    static var bundledModelsDirectory: URL? {
        Bundle.main.url(forResource: modelsFolderName, withExtension: nil)
    }

    let modelsDirectory: URL?

    init(modelsDirectory: URL? = SpeakerDiarizationService.bundledModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    /// Whether the models this service needs are present.
    var modelsAvailable: Bool {
        guard let modelsDirectory else { return false }
        return ModelFile.all.allSatisfy {
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
    }

    /// Finds who spoke when in `audioURL`. Silence, or audio too short to hold
    /// a turn, yields an empty result rather than an error.
    ///
    /// Throws `SpeakerDiarizationError`, or `CancellationError` when the
    /// calling task is cancelled. Cancellation is checked while converting the
    /// audio and between every analysis window.
    func diarize(audioURL: URL) async throws -> [SpeakerTurn] {
        _ = Self.enforceOfflineHub
        do {
            try Task.checkCancellation()
            guard let modelsDirectory, modelsAvailable else { throw SpeakerDiarizationError.modelsMissing }
            let audio = try DiarizationAudio.load(audioURL)
            let models = try await Self.loadModels(from: modelsDirectory)
            try Task.checkCancellation()

            let manager = OfflineDiarizerManager(config: Self.configuration)
            // Supplying the models up front is what keeps the manager from
            // calling `prepareModels()`, its only route to the model hub.
            manager.initialize(models: models)
            let result: DiarizationResult
            do {
                result = try await manager.process(audioSource: audio, audioLoadingSeconds: 0)
            } catch OfflineDiarizationError.noSpeechDetected {
                return []
            }
            try Task.checkCancellation()
            return Self.turns(
                from: result.segments.map {
                    RawTurn(
                        speakerID: $0.speakerId,
                        start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds)
                    )
                },
                audioDuration: audio.duration
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? SpeakerDiarizationError { throw error }
            throw SpeakerDiarizationError.failed
        }
    }

    /// FluidAudio's Community-1 defaults: a 10 s window stepped every 2 s,
    /// automatic speaker count, and non-overlapping output so every instant
    /// belongs to at most one speaker.
    static var configuration: OfflineDiarizerConfig { .default }

    /// FluidAudio documents that offline mode must be set before any of its
    /// loaders are touched. A lazily initialised static runs exactly once,
    /// thread-safely, before this service's first use of the library, and
    /// nothing else in Nook uses FluidAudio.
    private static let enforceOfflineHub: Void = {
        ModelHub.offlineMode = true
    }()

    // MARK: - Model output

    struct RawTurn: Equatable, Sendable {
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Model output is not trusted (AGENTS.md rule 6). Turns with non-finite
    /// or inverted times are dropped, the rest are clamped to the audio, and
    /// speakers are renumbered from 0 in order of first appearance, whatever
    /// identifiers the engine used.
    static func turns(from raw: [RawTurn], audioDuration: TimeInterval) -> [SpeakerTurn] {
        guard audioDuration.isFinite, audioDuration > 0 else { return [] }
        let clamped = raw.compactMap { turn -> RawTurn? in
            guard turn.start.isFinite, turn.end.isFinite else { return nil }
            let start = min(max(0, turn.start), audioDuration)
            let end = min(max(0, turn.end), audioDuration)
            guard end > start else { return nil }
            return RawTurn(speakerID: turn.speakerID, start: start, end: end)
        }
        let ordered = clamped.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            if lhs.element.end != rhs.element.end { return lhs.element.end < rhs.element.end }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var numbers: [String: Int] = [:]
        return ordered.map { turn in
            let speaker: Int
            if let existing = numbers[turn.speakerID] {
                speaker = existing
            } else {
                speaker = numbers.count
                numbers[turn.speakerID] = speaker
            }
            return SpeakerTurn(start: turn.start, end: turn.end, speaker: speaker)
        }
    }

    // MARK: - Models

    /// Loads the compiled models with Core ML directly. FBank runs on the CPU,
    /// where FluidAudio measured it fastest.
    ///
    /// The other three are kept off the GPU, unlike FluidAudio's `.all`
    /// default. On an M4 Pro that made no difference to speed (36 minutes of
    /// audio in 12 s either way) but allowing the GPU added about 230 MB to
    /// peak memory and kept it allocated after the call returned. Macs without
    /// a Neural Engine fall back to the CPU, which was about 2.5 times slower
    /// and still far faster than real time.
    private static func loadModels(from directory: URL) async throws -> OfflineDiarizerModels {
        let started = Date()
        do {
            let inference = MLModelConfiguration()
            inference.computeUnits = .cpuAndNeuralEngine
            let frontEnd = MLModelConfiguration()
            frontEnd.computeUnits = .cpuOnly

            let segmentation = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(ModelFile.segmentation), configuration: inference
            )
            let fbank = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(ModelFile.fbank), configuration: frontEnd
            )
            let embedding = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(ModelFile.embedding), configuration: inference
            )
            let pldaRho = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(ModelFile.pldaRho), configuration: inference
            )
            let psi = try pldaPsi(from: directory.appendingPathComponent(ModelFile.pldaParameters))
            return OfflineDiarizerModels(
                segmentationModel: segmentation,
                fbankModel: fbank,
                embeddingModel: embedding,
                pldaRhoModel: pldaRho,
                pldaPsi: psi,
                compilationDuration: Date().timeIntervalSince(started)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.modelsMissing
        }
    }

    /// The PLDA eigenvalues VBx clustering weighs embeddings by. FluidAudio's
    /// own reader is private to its hub loader, so this reads the same JSON:
    /// `tensors.psi.data_base64`, 128 little-endian Float32 values.
    static func pldaPsi(from url: URL) throws -> [Double] {
        struct Parameters: Decodable {
            struct Tensors: Decodable {
                struct Tensor: Decodable {
                    let dataBase64: String
                    enum CodingKeys: String, CodingKey { case dataBase64 = "data_base64" }
                }
                let psi: Tensor
            }
            let tensors: Tensors
        }
        let parameters = try JSONDecoder().decode(Parameters.self, from: Data(contentsOf: url))
        let width = MemoryLayout<UInt32>.size
        guard let bytes = Data(base64Encoded: parameters.tensors.psi.dataBase64, options: .ignoreUnknownCharacters),
              bytes.count == 128 * width else {
            throw SpeakerDiarizationError.modelsMissing
        }
        let values = bytes.withUnsafeBytes { raw in
            (0..<128).map { index in
                Double(Float32(bitPattern: UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: index * width, as: UInt32.self)
                )))
            }
        }
        guard values.allSatisfy(\.isFinite) else { throw SpeakerDiarizationError.modelsMissing }
        return values
    }
}
