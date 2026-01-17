//
//  WaveDanceMLView.swift
//  MyMetal
//
//  Created by Stan on 2025/12/7.
//

import AVFAudio
import Metal
import MetalKit
import simd


// MARK: - 核心视图类
public class WaveDanceMLView: MTKView {
    // MARK: - Metal 核心组件
    private var metalCommandQueue: MTLCommandQueue?
    private var metalPipelineState: MTLRenderPipelineState?
    private var computePipelineState: MTLComputePipelineState? // 计算管线
    private var computeOldPeakPipelineState: MTLComputePipelineState? // 计算管线
    private var copyCommandBuffer: MTLCommandBuffer? // 用于拷贝数据到私有缓冲区

    // MARK: - 顶点和 Uniform
    private struct Vertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// 实例化参数：拆分为4个float4（适配MTLVertexFormat)4 x 4 的变换矩阵，定点属性限制只能拆开传递
    private struct InstanceUniforms {
        var modelCol0: SIMD4<Float>
        var modelCol1: SIMD4<Float>
        var modelCol2: SIMD4<Float>
        var modelCol3: SIMD4<Float>
        var modeID: Int

        /// 便捷初始化：从float4x4转换为4个列向量
        init(matrix: float4x4, modeID: Int, viewAllCount: Int) {
            self.modelCol0 = matrix.columns.0
            self.modelCol1 = matrix.columns.1
            self.modelCol2 = matrix.columns.2
            self.modelCol3 = matrix.columns.3
            self.modeID = modeID
        }
    }

    private struct AnimationTimeUniform {
        var startTime: Float
        var currentTime: Float
        var totalDuration: Float
    }

    private enum GpuCommonFormat: UInt32, @unchecked Sendable {
        case otherFormat = 0
        case pcmFormatFloat32 = 1
        case pcmFormatFloat64 = 2
        case pcmFormatInt16 = 3
        case pcmFormatInt32 = 4
    }

    private struct ComputeUniforms {
        var animationTime: AnimationTimeUniform
        var gpuCommonFormat: UInt32
        var modelAllCount: Int
        var modelVertexCount: Int
    }

    private var gpuCommonFormat = GpuCommonFormat.otherFormat

    private struct ComputeOldUniforms {
        var animationTime: AnimationTimeUniform
        var gpuCommonFormat: UInt32
        var modelAllCount: Int
        var modelVertexCount: Int
    }

    private struct MainVertexUniforms {
        var mvp: float4x4 // MVP（投影+视图)
        var maxCenterStretch: Float
    }

    // 动画设置
    private var animationStartTime: Float = 0.0
    private var animationTotalDuration: Float = 0.5
    private var pcmPushFrequency: Float = 50
    private var frequencyCount: Float = 0
    private var viewAllCount = 4096
    public var maxCenterStretch: Float = 50.0
    public var angle:Float = 0.0

    // MARK: - 数据存储
    private var capsuleVertexBuffer: MTLBuffer? // GPU私有顶点缓冲区（仅1份，buffer 0)
    private var instanceBuffer: MTLBuffer? // GPU共享实例缓冲区（buffer 1)
    private var gpuPCMBuffer: MTLBuffer?
    private var animationProsBuffer: MTLBuffer? // 峰值缓存区

    /// 胶囊顶点数据 model scale = 1
    private let capsuleVertices: [Vertex] = {
        let w: Float = 0.5 // 缩小尺寸避免10个实例重叠
        let h: Float = 0.2
        let color = SIMD4<Float>(1.0, 1.0, 1.0, 1.0) // 白色
        let segmentCount = 10
        var vertices = [Vertex]()
        // 1. 长方形主体
        let p0 = Vertex(position: [-w / 2, h / 2, 0, 1], color: color)
        let p1 = Vertex(position: [w / 2, h / 2, 0, 1], color: color)
        let p2 = Vertex(position: [-w / 2, -h / 2, 0, 1], color: color)
        let p3 = Vertex(position: [w / 2, -h / 2, 0, 1], color: color)
        vertices.append(contentsOf: [p0, p1, p2, p2, p1, p3])
        // 2. 上半圆
        let topCenter = Vertex(position: [0, h / 2, 0, 1], color: color)
        for i in 0 ..< segmentCount {
            let angle1 = Float.pi * Float(i) / Float(segmentCount)
            let angle2 = Float.pi * Float(i + 1) / Float(segmentCount)
            let v1 = Vertex(position: [(w / 2) * cos(angle1), h / 2 + (w / 2) * sin(angle1), 0, 1], color: color)
            let v2 = Vertex(position: [(w / 2) * cos(angle2), h / 2 + (w / 2) * sin(angle2), 0, 1], color: color)
            vertices.append(contentsOf: [topCenter, v1, v2])
        }
        // 3. 下半圆
        let bottomCenter = Vertex(position: [0, -h / 2, 0, 1], color: color)
        for i in 0 ..< segmentCount {
            let angle1 = Float.pi + Float.pi * Float(i) / Float(segmentCount)
            let angle2 = Float.pi + Float.pi * Float(i + 1) / Float(segmentCount)
            let v1 = Vertex(position: [(w / 2) * cos(angle1), -h / 2 + (w / 2) * sin(angle1), 0, 1], color: color)
            let v2 = Vertex(position: [(w / 2) * cos(angle2), -h / 2 + (w / 2) * sin(angle2), 0, 1], color: color)
            vertices.append(contentsOf: [bottomCenter, v1, v2])
        }
        return vertices
    }()

    /// viewAllCount obj  变换矩阵
    private lazy var instanceModelMatrices: [InstanceUniforms] = {
        guard viewAllCount > 0 else { return [] }
        let spacing: Float = 1.0
        let midOffset = (Float(viewAllCount) - 1) / 2.0
        var matrices = [InstanceUniforms]()
        for i in 0 ..< viewAllCount {
            let iFloat = Float(i)
            // 3. 最终偏移量 = (索引 - 中点) * 间距系数
            let xOffset = (iFloat - midOffset) * spacing
            let translateMatrix = float4x4.translate(SIMD3<Float>(xOffset, 0, 0))
            matrices.append(InstanceUniforms(matrix: translateMatrix, modeID: i, viewAllCount: viewAllCount))
        }
        return matrices
    }()

    var camera = Camera(position: SIMD3<Float>(0, 0, 100)) // 拉远相机看清10个实例

    // MARK: - 指定初始化器
    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil {
            device = MTLCreateSystemDefaultDevice()
        }
        commonInit()
    }

    private func commonInit() {
        guard let device else {
            print("当前设备不支持 Metal！")
            return
        }
        // 背景透明
        colorPixelFormat = .rgba8Unorm // 必须带 Alpha 通道
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) // 背景透明
        // model 缩小时平滑过度提出毛刺
        sampleCount = 4 // 4x采样（2pt宽度足够，8x会增加性能开销)
        depthStencilPixelFormat = .depth32Float

        // MTKView 配置
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
        preferredFramesPerSecond = 60  //主渲染管线的频率

        // 初始化命令队列（用于拷贝数据到私有缓冲区)
        metalCommandQueue = device.makeCommandQueue()
        copyCommandBuffer = metalCommandQueue?.makeCommandBuffer()

        setupRenderPipeline()
        setupComputePipeline() // 初始化计算管线
        setupComputeOldPeakPipeline()
        setupGPUBuffers() // 初始化GPU缓冲区
    }

    // MARK: - 计算管线创建
    private func setupComputePipeline() {
        guard let device else { return }
        guard let library = device.makeDefaultLibrary() else {
            print("无法加载默认 Metal 库")
            return
        }
        // 创建 compute_peak_kernel 对应的计算函数
        guard let computeFunction = library.makeFunction(name: "compute_peak_kernel") else {
            print("Metal 库中找不到 compute_peak_kernel 函数！")
            return
        }
        // 创建计算管线
        do {
            computePipelineState = try device.makeComputePipelineState(function: computeFunction)
        } catch {
            print("创建计算管线失败: \(error)")
        }
    }

    private func setupComputeOldPeakPipeline() {
        guard let device else { return }
        guard let library = device.makeDefaultLibrary() else {
            print("无法加载默认 Metal 库")
            return
        }
        // 创建 compute_peak_kernel 对应的计算函数
        guard let computeFunction = library.makeFunction(name: "compute_old_peak_kernel") else {
            print("Metal 库中找不到 compute_peak_kernel 函数！")
            return
        }
        // 创建计算管线
        do {
            computeOldPeakPipelineState = try device.makeComputePipelineState(function: computeFunction)
        } catch {
            print("创建计算管线失败: \(error)")
        }
    }

    // MARK: - 初始化GPU缓冲区（核心修复storageModePrivate创建逻辑)
    private func setupGPUBuffers() {
        guard let device, let copyCmdBuffer = copyCommandBuffer else { return }

        // i：创建mode的GPU私有缓冲区
        let vertexBufferSize = MemoryLayout<Vertex>.stride * capsuleVertices.count
        guard let capsuleVertexBuffer = device.makeBuffer(length: vertexBufferSize, options: .storageModePrivate) else { return }
        self.capsuleVertexBuffer = capsuleVertexBuffer

        // ii：model拷贝到共享缓冲区CPU/GPU
        guard let tempVertexBuffer = device.makeBuffer(
            bytes: capsuleVertices,
            length: vertexBufferSize,
            options: .storageModeShared
        ) else { return }

        // iii：model从共享缓冲区拷贝GPU私有缓冲区
        let blitEncoder = copyCmdBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(from: tempVertexBuffer, sourceOffset: 0,
                         to: capsuleVertexBuffer, destinationOffset: 0,
                         size: vertexBufferSize)
        blitEncoder.endEncoding()
        copyCmdBuffer.commit()
        copyCmdBuffer.waitUntilCompleted() // 等待拷贝完成

        // ========== 变换矩阵拷贝到（CPU/GPU共享) 缓存区==========
        let instanceBufferSize = MemoryLayout<InstanceUniforms>.stride * instanceModelMatrices.count
        guard let instanceBuffer = device.makeBuffer(
            bytes: instanceModelMatrices,
            length: instanceBufferSize,
            options: .storageModeShared
        ) else { return }
        self.instanceBuffer = instanceBuffer

        // pcm数据缓存区
        let bufferSize = MemoryLayout<Float64>.stride * 4096
        guard let buffer = device.makeBuffer(
            length: bufferSize,
            options: .storageModeShared)
        else { return }
        // 全0初始化
        memset(buffer.contents(), 0, bufferSize)
        self.gpuPCMBuffer = buffer

        // 峰值缓存区 CPU/GPU
        let kArrayCount = 4096
        let kFloatSize = MemoryLayout<Float>.stride
        let kBoolSize = MemoryLayout<Bool>.stride
        // AnimationProsBuffer 总大小 = 3个float数组 + 1个bool数组
        let kAnimationProsBufferSize = (kArrayCount * kFloatSize) * 3 + (kArrayCount * kBoolSize)
        guard let buffer = device.makeBuffer(
            length: kAnimationProsBufferSize,
            options: .storageModeShared
        ) else { return }
        // 2. 初始化缓冲区为全0（和 Metal 端默认值一致)
        buffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: kAnimationProsBufferSize)
        self.animationProsBuffer = buffer
    }

    // MARK: - 渲染管线创建
    private func setupRenderPipeline() {
        guard let device else { return }
        guard let library = device.makeDefaultLibrary() else {
            print("无法加载默认 Metal 库")
            return
        }

        // 渲染管线
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "fragment_main")
        pipelineDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        // model 缩小时平滑过度提出毛刺
        pipelineDesc.sampleCount = sampleCount // 匹配MTKView的4x采样
        pipelineDesc.depthAttachmentPixelFormat = depthStencilPixelFormat

        // 定点数据块描述
        let vertexDescriptor = MTLVertexDescriptor()

        // ========== model 矩阵 ==========
        // 数据块  layouts = 0 ，0 1 两个属性
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride // 数据块的大小
        vertexDescriptor.layouts[0].stepFunction = .perVertex // 读取的频率
        // position
        vertexDescriptor.attributes[0].format = .float4 // 0个属性
        vertexDescriptor.attributes[0].offset = 0 // 在数据模块偏移 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // color
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        // ========== 变换矩阵 ==========
        // 数据块 1
        vertexDescriptor.layouts[1].stride = MemoryLayout<InstanceUniforms>.stride
        vertexDescriptor.layouts[1].stepFunction = .perInstance
        // modelMatrix列0（float4)
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = 0
        vertexDescriptor.attributes[2].bufferIndex = 1
        // modelMatrix列1（float4)
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[3].bufferIndex = 1
        // modelMatrix列2（float4)
        vertexDescriptor.attributes[4].format = .float4
        vertexDescriptor.attributes[4].offset = MemoryLayout<SIMD4<Float>>.stride * 2
        vertexDescriptor.attributes[4].bufferIndex = 1
        // modelMatrix列3（float4)
        vertexDescriptor.attributes[5].format = .float4
        vertexDescriptor.attributes[5].offset = MemoryLayout<SIMD4<Float>>.stride * 3
        vertexDescriptor.attributes[5].bufferIndex = 1

        // ========== 其他参数 ==========
        // mode ID（Int)
        vertexDescriptor.attributes[6].format = .int
        vertexDescriptor.attributes[6].offset = MemoryLayout<SIMD4<Float>>.stride * 4
        vertexDescriptor.attributes[6].bufferIndex = 1
        // mode all count
        vertexDescriptor.attributes[7].format = .int
        vertexDescriptor.attributes[7].offset = MemoryLayout<SIMD4<Float>>.stride * 4 + MemoryLayout<SIMD4<Int>>.stride
        vertexDescriptor.attributes[7].bufferIndex = 1

        pipelineDesc.vertexDescriptor = vertexDescriptor

        do {
            metalPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            print("创建渲染管线失败")
        }
    }

    // MARK: - 执行计算着色器  1/44 s
    private func runComputeOldShader() {
        guard let computeOldPeakPipelineState = self.computeOldPeakPipelineState,
              let commandBuffer = metalCommandQueue?.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        // 1. 设置计算管线
        computeEncoder.setComputePipelineState(computeOldPeakPipelineState)
        // 4. 绑定 AnimationProsBuffer（buffer 4)
        if let animationProsBuffer {
            computeEncoder.setBuffer(animationProsBuffer, offset: 0, index: 4)
        }
        // 5. 配置线程组（核心：总线程数 = 模型数 * 单模型顶点数)
        let totalThreads = viewAllCount
        let threadGroupSize = MTLSize(width: 256, height: 1, depth: 1) // 通用线程大小
        let threadGroups = MTLSize(
            width: (totalThreads + threadGroupSize.width - 1) / threadGroupSize.width,
            height: 1,
            depth: 1
        )
        // 6. 执行计算
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        // 7. 提交并等待完成（确保绘制前数据更新)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - 执行计算着色器 1/60 在主渲染管线前计算动画进度
    private func runComputeShader() {
        guard let computePipelineState = self.computePipelineState,
              let device,
              let commandBuffer = metalCommandQueue?.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        // 1. 设置计算管线
        computeEncoder.setComputePipelineState(computePipelineState)

        var computeUniforms = ComputeUniforms(
            animationTime: AnimationTimeUniform(
                startTime: animationStartTime,
                currentTime: Float(CACurrentMediaTime()),
                totalDuration: animationTotalDuration
            ),
            gpuCommonFormat: gpuCommonFormat.rawValue,
            modelAllCount: viewAllCount,
            modelVertexCount: capsuleVertices.count
        )
        // 创建临时 buffer 存储 uniforms（计算着色器不支持 setVertexBytes)
        let uniformsBuffer = device.makeBuffer(length: MemoryLayout<ComputeUniforms>.stride, options: .storageModeShared)!
        memcpy(uniformsBuffer.contents(), &computeUniforms, MemoryLayout<ComputeUniforms>.stride)
        computeEncoder.setBuffer(uniformsBuffer, offset: 0, index: 5)

        // 3. 绑定 PCM 缓冲区（buffer 3)
        if let gpuPCMBuffer {
            computeEncoder.setBuffer(gpuPCMBuffer, offset: 0, index: 3)
        }
        // 4. 绑定 AnimationProsBuffer（buffer 4)
        if let animationProsBuffer {
            computeEncoder.setBuffer(animationProsBuffer, offset: 0, index: 4)
        }
        // 5. 配置线程组（核心：总线程数 = 模型数 * 单模型顶点数)
        let totalThreads = viewAllCount
        let threadGroupSize = MTLSize(width: 256, height: 1, depth: 1) // 通用线程大小
        let threadGroups = MTLSize(
            width: (totalThreads + threadGroupSize.width - 1) / threadGroupSize.width,
            height: 1,
            depth: 1
        )
        // 6. 执行计算
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        // 7. 提交并等待完成（确保绘制前数据更新)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - 实时绘制绘制1/60s 主渲染管线
    private func drawInstances(renderEncoder: MTLRenderCommandEncoder) {
        guard let metalPipelineState = self.metalPipelineState else { return }
        renderEncoder.setRenderPipelineState(metalPipelineState)

        var model = float4x4.identity()
        model = model * float4x4.rotate(angle: angle, axis: SIMD3<Float>(0, 1, 0))

        // 1. 绑定顶点缓冲区   （buffer 0)
        renderEncoder.setVertexBuffer(capsuleVertexBuffer, offset: 0, index: 0)
        // 2. 绑定变换矩阵缓冲区（buffer 1)
        renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        // 3.绑定 Uniforms   （buffer 2)
        let view = camera.getViewMatrix()
        let aspect = Float(drawableSize.width / drawableSize.height)
        let projection = float4x4.perspective(fovY: radians(camera.zoom), aspect: aspect, near: 0.1, far: 1000)
        let MVP = projection * view * model // 计算MVP
        var uniforms = MainVertexUniforms(mvp: MVP, maxCenterStretch: maxCenterStretch)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<MainVertexUniforms>.stride, index: 2)
        // 6.绑定 峰值 共享
        renderEncoder.setVertexBuffer(animationProsBuffer, offset: 0, index: 4)
        // 7. 绘制n个实例
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: capsuleVertices.count,
            instanceCount: self.viewAllCount
        )
    }

    /// 供外部调用的刷新方法
    public func refreshRender() {
        setNeedsDisplay()
    }

    // MARK: - 不定时的跟新 1/44 s 计算的频率和pcm跟新的频率一样,开始新的动画,添入新的峰值,跟新老的峰值,
    public func pushPCMtoGPU(buffer: AVAudioPCMBuffer, count: Int) {
//        if count > 1024 {
//            return
//        }
        printAnimationProsBuffer(animationProsBuffer, maxPrintCount: 3)
        frequencyCount += 1
        if frequencyCount < (1/pcmPushFrequency) * 44.0 {
            return
        } else {
            frequencyCount = 0
        }
        self.runComputeOldShader() // 计算老的动画

        print("======pcm buffer push======")
        printAnimationProsBuffer(animationProsBuffer, maxPrintCount: 1)

        let format = buffer.format
        // 1. 公共前置校验
        guard let gpuPCMBuffer = self.gpuPCMBuffer,
              let (srcPtr, stride, pushAudioFormat) = getPCMDataPtrAndStride(buffer: buffer, format: format) else {
            return
        }
        // 2. 越界校验
        let bytesToCopy = stride * count // push 包的长度
        guard bytesToCopy > 0, bytesToCopy <= gpuPCMBuffer.length else {
            return
        }
        self.gpuCommonFormat = pushAudioFormat

        // 3. 拷贝音频数共享缓存区 ==== 音频数据入口
        gpuPCMBuffer.contents().copyMemory(from: srcPtr, byteCount: bytesToCopy)
        self.animationStartTime = Float(CACurrentMediaTime()) // 动画开始时间
    }

    // MARK: - 匹配内存结构
    private func getPCMDataPtrAndStride(buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> (UnsafeRawPointer, Int, GpuCommonFormat)? {
        switch format.commonFormat {
        case .otherFormat:
            return nil

        case .pcmFormatFloat32:
            guard let float32Ptr = buffer.floatChannelData else { return nil }
            return (UnsafeRawPointer(float32Ptr.pointee), MemoryLayout<Float32>.stride, .pcmFormatFloat32)

        case .pcmFormatFloat64:
            return nil

        case .pcmFormatInt16:
            guard let int16Ptr = buffer.int16ChannelData else { return nil }
            return (UnsafeRawPointer(int16Ptr.pointee), MemoryLayout<Int16>.stride, .pcmFormatInt16)

        case .pcmFormatInt32:
            guard let int32Ptr = buffer.int32ChannelData else { return nil }
            return (UnsafeRawPointer(int32Ptr.pointee), MemoryLayout<Int32>.stride, .pcmFormatInt32)

        @unknown default:
            return nil
        }
    }

    private enum AnimationProsBuffer { // 和作色器对齐 4096
        static let arrayCount = 4096
        static var totalSize: Int {
            let floatStride = MemoryLayout<Float>.stride
            let boolStride = MemoryLayout<UInt32>.stride
            return floatStride * arrayCount * 3 + boolStride * arrayCount
        }
    }
}

// MARK: - MTKViewDelegate
extension WaveDanceMLView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let metalCommandQueue,
              let commandBuffer = metalCommandQueue.makeCommandBuffer(),
              let renderPassDescriptor = currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        // 并行计算高度
        self.runComputeShader()
        // 绘制
        drawInstances(renderEncoder: renderEncoder)
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension WaveDanceMLView {
    func printAnimationProsBuffer(_ buffer: MTLBuffer?, modelID: Int? = nil, maxPrintCount: Int = 1) {
        guard let buffer else {
            print("⚠️ 峰值缓冲区未初始化")
            return
        }

        let floatStride = MemoryLayout<Float>.stride
        _ = MemoryLayout<UInt32>.stride
        let arrayCount = AnimationProsBuffer.arrayCount

        // 计算各字段内存偏移
        let animOffset = 0
        let targetOffset = animOffset + floatStride * arrayCount
        let oldOffset = targetOffset + floatStride * arrayCount
        let initOffset = oldOffset + floatStride * arrayCount

        // 绑定各字段指针
        let animPtr = buffer.contents().advanced(by: animOffset).assumingMemoryBound(to: Float.self)
        let targetPtr = buffer.contents().advanced(by: targetOffset).assumingMemoryBound(to: Float.self)
        let oldPtr = buffer.contents().advanced(by: oldOffset).assumingMemoryBound(to: Float.self)
        let initPtr = buffer.contents().advanced(by: initOffset).assumingMemoryBound(to: UInt32.self)

        let printCount = min(maxPrintCount, arrayCount)
        print("----模型ID---动画进度--目标峰值--历史峰值---是否初始化")
        print("---------------------------------------------------")
        for i in 0 ..< printCount {
            let initStatus = initPtr[i] != 0 ? "✅" : "❌"
            let str = String(format: "%6d | %8.4f | %8.4f | %8.4f | %10@", i, animPtr[i], targetPtr[i], oldPtr[i], initStatus)
            print("\(str)")
        }
        print("---------------------------------------------------")
    }
}
