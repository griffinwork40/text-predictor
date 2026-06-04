// Inference.swift — mlx-swift-lm wrapper. Ports the LogprobCapture pattern
// from text-predictor-spike/. M1A doesn't yet act on the score (no confidence
// gate), but the capture stays wired so M1B can switch it on by reading a
// single field.

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

actor Inference {
    private var container: ModelContainer?

    func loadIfNeeded() async throws {
        if container != nil { return }
        let t0 = Date()
        container = try await #huggingFaceLoadModelContainer(
            configuration: LLMRegistry.qwen3_1_7b_4bit
        )
        log.info("Model loaded in \(Date().timeIntervalSince(t0))s")
    }

    /// Loads the model and runs a tiny throwaway inference so Metal kernels
    /// get JIT'd on a background task. Without this, the user's first
    /// Ctrl+Space pays the ~550ms cold-start tax.
    func warmup() async throws {
        try await loadIfNeeded()
        _ = try await predict(prompt: "Hello ", maxTokens: 3)
        log.info("Inference warmup complete.")
    }

    /// Generate up to `maxTokens` tokens from `prompt` and return the decoded
    /// string. Honors Task cancellation between tokens.
    func predict(prompt: String, maxTokens: Int) async throws -> String {
        try await loadIfNeeded()
        guard let container else { throw InferenceError.notLoaded }

        return try await container.perform { (ctx: ModelContext) -> String in
            let promptTokens = ctx.tokenizer.encode(text: prompt)
            let input = LMInput(tokens: MLXArray(promptTokens))

            let capture = LogprobCapture()
            let sampler = ArgMaxSampler()  // deterministic for M1A

            let iter = try TokenIterator(
                input: input,
                model: ctx.model,
                cache: nil,
                processor: capture,
                sampler: sampler,
                prefillStepSize: 512,
                maxTokens: maxTokens
            )

            let stopTokenIds: Set<Int> = {
                var s: Set<Int> = []
                if let eos = ctx.tokenizer.eosTokenId { s.insert(eos) }
                for tok in ctx.configuration.extraEOSTokens {
                    if let id = ctx.tokenizer.convertTokenToId(tok) { s.insert(id) }
                }
                return s
            }()

            var ids: [Int] = []
            for token in iter {
                if Task.isCancelled { break }
                if stopTokenIds.contains(token) { break }
                ids.append(token)
            }

            Stream().synchronize()
            return ctx.tokenizer.decode(tokenIds: ids)
        }
    }
}

enum InferenceError: Error {
    case notLoaded
}

/// Lifted from text-predictor-spike/. M1A doesn't read `entries` yet; M1B
/// will compute a length-normalized log-prob and gate rendering on it.
final class LogprobCapture: LogitProcessor, @unchecked Sendable {
    struct Entry {
        let tokenId: Int
        let logprob: Float
    }

    private(set) var entries: [Entry] = []
    private var pendingLogprobs: MLXArray?

    func prompt(_ prompt: MLXArray) {
        entries = []
        pendingLogprobs = nil
    }

    func process(logits: MLXArray) -> MLXArray {
        let lp = MLXNN.logSoftmax(logits, axis: -1)
        eval(lp)
        pendingLogprobs = lp
        return logits
    }

    func didSample(token: MLXArray) {
        guard let lp = pendingLogprobs else { return }
        let id = token.item(Int.self)
        let logprob = lp[0, id].item(Float.self)
        entries.append(Entry(tokenId: id, logprob: logprob))
        pendingLogprobs = nil
    }
}
