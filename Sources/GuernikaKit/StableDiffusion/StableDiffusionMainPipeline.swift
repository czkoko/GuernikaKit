//
//  StableDiffusionPipeline.swift
//  
//
//  Created by Guillermo Cique Fernández on 25/5/23.
//

import CoreML
import Schedulers
import Accelerate
import CoreGraphics
import RandomGenerator

/// A pipeline used to generate image samples from text input using stable diffusion
///
/// This implementation matches:
/// [Hugging Face Diffusers Pipeline](https://github.com/huggingface/diffusers/blob/main/src/diffusers/pipelines/stable_diffusion/pipeline_stable_diffusion.py)
public class StableDiffusionMainPipeline: StableDiffusionPipeline {
    public let baseUrl: URL
    /// Model to generate embeddings for tokenized input text
    public let textEncoder: TextEncoder
    public var overrideTextEncoder: TextEncoder?
    /// Model used to generate initial image for latent diffusion process
    var encoder: Encoder? = nil
    /// Models used to control diffusion models by adding extra conditions
    public var controlNets: [ControlNet.Input] = [] {
        didSet {
            // Only allow compatible ControlNets
            controlNets = controlNets.filter { $0.controlNet.hiddenSize == unet.hiddenSize }
        }
    }
    /// Model used to predict noise residuals given an input, diffusion time step, and conditional embedding
    public var unet: Unet
    /// Model used to generate final image from latent diffusion process
    public var decoder: Decoder
    /// Optional model for checking safety of generated image
    public var safetyChecker: SafetyChecker? = nil
    
    public var disableSafety: Bool = false {
        didSet {
            if !disableSafety {
                safetyChecker?.unloadResources()
            }
        }
    }

    /// Option to reduce memory during image generation
    ///
    /// If true, the pipeline will lazily load TextEncoder, Unet, Decoder, and SafetyChecker
    /// when needed and aggressively unload their resources after
    ///
    /// This will increase latency in favor of reducing memory
    public var reduceMemory: Bool = false
    
    /// Reports whether this pipeline can perform image to image
    public var canGenerateVariations: Bool {
        encoder != nil
    }
    
    public var computeUnits: ComputeUnits {
        didSet {
            guard computeUnits != oldValue else { return }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits.mlComputeUnits(for: unet.attentionImplementation)
            textEncoder.configuration = configuration
            encoder?.configuration = configuration
            unet.configuration = configuration
            decoder.configuration = configuration
            safetyChecker?.configuration = configuration
        }
    }

    /// Creates a pipeline using the specified models and tokenizer
    ///
    /// - Parameters:
    ///   - textEncoder: Model for encoding tokenized text
    ///   - unet: Model for noise prediction on latent samples
    ///   - decoder: Model for decoding latent sample to image
    ///   - safetyChecker: Optional model for checking safety of generated images
    ///   - guidanceScale: Influence of the text prompt on generation process
    /// - Returns: Pipeline ready for image generation
    public init(
        baseUrl: URL,
        textEncoder: TextEncoder,
        encoder: Encoder? = nil,
        unet: Unet,
        decoder: Decoder,
        safetyChecker: SafetyChecker? = nil,
        computeUnits: ComputeUnits = .auto,
        reduceMemory: Bool = false
    ) {
        self.baseUrl = baseUrl
        self.textEncoder = textEncoder
        self.encoder = encoder
        self.unet = unet
        self.decoder = decoder
        self.safetyChecker = safetyChecker
        self.computeUnits = computeUnits
        self.reduceMemory = reduceMemory
    }

    /// Unload the underlying resources to free up memory
    public func unloadResources() {
        textEncoder.unloadResources(clearCache: true)
        overrideTextEncoder?.unloadResources(clearCache: true)
        encoder?.unloadResources(clearCache: true)
        unet.unloadResources()
        controlNets.forEach { $0.controlNet.unloadResources() }
        decoder.unloadResources()
        safetyChecker?.unloadResources()
    }
    
    /// Text to image generation using stable diffusion
    ///
    /// - Parameters:
    ///   - prompt: Text prompt to guide sampling
    ///   - stepCount: Number of inference steps to perform
    ///   - imageCount: Number of samples/images to generate for the input prompt
    ///   - seed: Random seed which
    ///   - disableSafety: Safety checks are only performed if `self.canSafetyCheck && !disableSafety`
    ///   - progressHandler: Callback to perform after each step, stops on receiving false response
    /// - Returns: An array of `imageCount` optional images.
    ///            The images will be nil if safety checks were performed and found the result to be un-safe
    public func generateImages(
        input: SampleInput,
        progressHandler: (StableDiffusionProgress) -> Bool = { _ in true }
    ) throws -> CGImage? {
#if DEBUG
        let mainTick = CFAbsoluteTimeGetCurrent()
#endif
        let hiddenStates = try hiddenStates(prompt: input.prompt, negativePrompt: input.negativePrompt)
        
        let generator: RandomGenerator = TorchRandomGenerator(seed: input.seed)
        let scheduler: Scheduler = input.scheduler.create(
            strength: input.strength, stepCount: input.stepCount, predictionType: unet.predictionType
        )

        // Generate random latent sample from specified seed
        var (latent, noise, imageLatent) = try prepareLatent(input: input, generator: generator, scheduler: scheduler)
        // Prepare mask only for inpainting
        let (mask, maskedImage) = try prepareMaskLatents(input: input, generator: generator)
        
        if reduceMemory {
            encoder?.unloadResources()
        }

        // De-noising loop
        for (step, t) in scheduler.timeSteps.enumerated() {
            // Expand the latents for classifier-free guidance
            // and input to the Unet noise prediction model
            var latentUnetInput = MLShapedArray<Float32>(concatenating: [latent, latent], alongAxis: 0)
            
            latentUnetInput = scheduler.scaleModelInput(timeStep: t, sample: latentUnetInput)
            
            if unet.function == .inpaint {
                guard let mask, let maskedImage else {
                    throw StableDiffusionError.missingInputs
                }
                // Concat mask in case we are doing inpainting
                latentUnetInput = MLShapedArray<Float32>(concatenating: [latentUnetInput, mask, maskedImage], alongAxis: 1)
            }
            
            let additionalResiduals = try controlNets.predictResiduals(
                latent: latentUnetInput,
                timeStep: t,
                hiddenStates: hiddenStates
            )

            // Predict noise residuals from latent samples
            // and current time step conditioned on hidden states
            var noisePrediction = try unet.predictNoise(
                latents: [latentUnetInput],
                additionalResiduals: additionalResiduals.map { [$0] },
                timeStep: t,
                hiddenStates: hiddenStates
            )[0]

            noisePrediction = performGuidance(noisePrediction, guidanceScale: input.guidanceScale)

            // Have the scheduler compute the previous (t-1) latent
            // sample given the predicted noise and current sample
            latent = scheduler.step(
                output: noisePrediction,
                timeStep: t,
                sample: latent,
                generator: generator
            )
            
            if let mask, let noise, let imageLatent, unet.function != .inpaint {
                var initLatentProper = imageLatent
                if step < scheduler.timeSteps.count - 1 {
                    let noiseTimeStep = scheduler.timeSteps[step + 1]
                    initLatentProper = scheduler.addNoise(
                        originalSample: initLatentProper,
                        noise: [noise],
                        timeStep: noiseTimeStep
                    )[0]
                }
                latent = MLShapedArray<Float>(unsafeUninitializedShape: latent.shape) { result, _ in
                    mask.withUnsafeShapedBufferPointer { maskScalars, _, _ in
                        latent.withUnsafeShapedBufferPointer { latentScalars, _, _ in
                            initLatentProper.withUnsafeShapedBufferPointer { initScalars, _, _ in
                                for i in 0..<result.count {
                                    // (1 - init_mask) * init_latents_proper + init_mask * latents
                                    let maskScalar = maskScalars[i % maskScalars.count]
                                    result.initializeElement(
                                        at: i,
                                        to: (1 - maskScalar) * initScalars[i] + maskScalar * latentScalars[i]
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Report progress
            let progress = StableDiffusionProgress(
                pipeline: self,
                input: input,
                step: step,
                stepCount: scheduler.timeSteps.count - 1,
                currentLatentSample: latent
            )
            if !progressHandler(progress) {
                // Stop if requested by handler
                return nil
            }
        }
        
        if reduceMemory {
            controlNets.forEach { $0.controlNet.unloadResources() }
            unet.unloadResources()
        }

        // Decode the latent sample to image
        let image = try decodeToImage(latent)
        
        if reduceMemory {
            decoder.unloadResources()
        }
        
#if DEBUG
        let mainTock = CFAbsoluteTimeGetCurrent()
        let runtime = String(format:"%.2fs", mainTock - mainTick)
        print("Time", runtime)
#endif
        return image
    }
    
    func prepareLatent(
        input: SampleInput,
        generator: RandomGenerator,
        scheduler: Scheduler
    ) throws -> (MLShapedArray<Float32>, MLShapedArray<Float32>?, MLShapedArray<Float32>?) {
        var sampleShape = unet.latentSampleShape
        sampleShape[0] = 1
        sampleShape[1] = 4
        
        let latent: MLShapedArray<Float32>
        let noise: MLShapedArray<Float32>?
        var imageLatent: MLShapedArray<Float32>?
        if let image = input.initImage, let strength = input.strength {
            guard let encoder else {
                throw StableDiffusionError.encoderMissing
            }
            if unet.function != .inpaint || strength < 1 {
                imageLatent = try encoder.encode(image, generator: generator)
            }
            if strength >= 1 {
                let stdev = scheduler.initNoiseSigma
                noise = generator.nextArray(shape: sampleShape, mean: 0, stdev: stdev)
                latent = noise!
            } else {
                noise = generator.nextArray(shape: sampleShape, mean: 0, stdev: 1)
                latent = scheduler.addNoise(originalSample: imageLatent!, noise: [noise!])[0]
            }
        } else {
            let stdev = scheduler.initNoiseSigma
            latent = generator.nextArray(shape: sampleShape, mean: 0, stdev: stdev)
            // Not needed for text to image
            noise = nil
            imageLatent = nil
        }
        
        return (latent, noise, imageLatent)
    }
    
    func prepareMaskLatents(input: SampleInput, generator: RandomGenerator) throws -> (MLShapedArray<Float32>?, MLShapedArray<Float32>?) {
        guard let image = input.initImage, let mask = input.inpaintMask else {
            return (nil, nil)
        }
        guard let encoder else {
            throw StableDiffusionError.encoderMissing
        }
        var imageData = image.toShapedArray()
        var maskData = mask.toAlphaShapedArray()
        imageData = MLShapedArray(unsafeUninitializedShape: imageData.shape) { result, _ in
            imageData.withUnsafeShapedBufferPointer { image, _, _ in
                maskData.withUnsafeShapedBufferPointer { mask, _, _ in
                    for i in 0..<result.count {
                        let maskScalar: Float32 = mask[i % mask.count] < 0.5 ? 1 : 0
                        result.initializeElement(at: i, to: image[i] * maskScalar)
                    }
                }
            }
        }
        
        // Encode the mask image into latents space so we can concatenate it to the latents
        var maskedImageLatent = try encoder.encode(imageData, generator: generator)
        
        let resizedMask = mask.scaledAspectFill(size: CGSize(width: maskedImageLatent.shape[3], height: maskedImageLatent.shape[2]))
        maskData = resizedMask.toAlphaShapedArray()
        
        // Expand the latents for classifier-free guidance
        // and input to the Unet noise prediction model
        if unet.function == .inpaint {
            maskData = MLShapedArray<Float32>(concatenating: [maskData, maskData], alongAxis: 0)
        }
        maskedImageLatent = MLShapedArray<Float32>(concatenating: [maskedImageLatent, maskedImageLatent], alongAxis: 0)
        
        return (maskData, maskedImageLatent)
    }

    func performGuidance(_ noise: [MLShapedArray<Float32>], guidanceScale: Float) -> [MLShapedArray<Float32>] {
        noise.map { performGuidance($0, guidanceScale: guidanceScale) }
    }

    func performGuidance(_ noise: MLShapedArray<Float32>, guidanceScale: Float) -> MLShapedArray<Float32> {
        var shape = noise.shape
        shape[0] = 1
        return MLShapedArray<Float>(unsafeUninitializedShape: shape) { result, _ in
            noise.withUnsafeShapedBufferPointer { scalars, _, strides in
                for i in 0..<result.count {
                    // unconditioned + guidance*(text - unconditioned)
                    result.initializeElement(
                        at: i,
                        to: scalars[i] + guidanceScale * (scalars[strides[0] + i] - scalars[i])
                    )
                }
            }
        }
    }
}