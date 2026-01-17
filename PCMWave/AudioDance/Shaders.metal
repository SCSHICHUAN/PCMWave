//
//  WaveDanceMLView.swift
//  MyMetal
//
//  Created by Stan on 2025/12/7.
//


#define CLAMP01(x) clamp(x, 0.0, 1.0)
#define max_view_count 4096
#include <metal_stdlib>
using namespace metal;


enum GpuCommonFormat : uint {
    pcmFormatFloat32 = 1,
    pcmFormatFloat64 = 2,
    pcmFormatInt16 = 3,
    pcmFormatInt32 = 4,
};

struct VertexIn {
    // 顶点属性（per vertex）
    float4 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    
    // 实例属性（per instance，拆分为4个float4）
    float4 modelCol0 [[attribute(2)]];
    float4 modelCol1 [[attribute(3)]];
    float4 modelCol2 [[attribute(4)]];
    float4 modelCol3 [[attribute(5)]];
    int      modelID [[attribute(6)]];
    
    // 便捷方法：拼接实例矩阵
    float4x4 transformMatrix() const {
        return float4x4(modelCol0,
                        modelCol1,
                        modelCol2,
                        modelCol3);
    }
};

    
/*
    Private    仅 GPU 显存    CPU 不可访问，GPU 高速访问    速度最快，但数据无法共享
    Managed    CPU 内存 + GPU 显存    CPU/GPU 都可访问，需手动同步    数据会拷贝，有延迟
    Shared     统一内存（UM）    CPU/GPU 实时读写同一块内存    无拷贝、无延迟，适合实时共享
*/
// 实例峰值缓冲区 CPU/GPU , CPU把PCM直接拷贝到共享缓存中,在CPU和着色器之间互相读取和计算
struct AnimationProsBuffer {
    float animationPros[max_view_count];   // 当前动画的进度
    float targetAmplitude[max_view_count]; // 目标峰值
    float oldAmplitude[max_view_count];    // 老的峰值
    bool  isInitialized[max_view_count];   // 是否已经初始化
};
struct AnimationTimeUniform {
    float startTime;    // 开始时间
    float currentTime;  // 当前时间
    float totalDuration; // 这次动画总时间
};
// ComputeUniforms（buffer 2）
struct ComputeUniforms {
    AnimationTimeUniform  animationTime;
    GpuCommonFormat pcmFormat;
    int  modelAllCount;
    int  modelVertexCount;
};

// Uniforms（buffer 2）
struct MainVertexUniforms {
    float4x4 mvp;
    float maxCenterStretch;
};

// 全局PCM缓冲区（buffer 3）
struct AudioPCMBufferUniforms {
    union {
        float float32Data[1024];
        int16_t int16Data[1024];
        int32_t int32Data[1024];
    } pcmData;
};

//定点数据结构
struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// 归一化PCM
float normalizationPcmData(constant AudioPCMBufferUniforms& pcmBuffer,
                           constant GpuCommonFormat& pcmFormat,
                           int modelID,
                           int modelAllCount){
    
    float amplitude = 0.0;
    int dataSpace = max_view_count / modelAllCount; // 从连续内存中读取数据
    int dataOffset = dataSpace * modelID;
    if (dataOffset < 0 || dataOffset > max_view_count){
        dataOffset = max_view_count;
    }
    
    switch (pcmFormat){
        case pcmFormatFloat32:
            amplitude = float(pcmBuffer.pcmData.float32Data[dataOffset]);
            break;
        case pcmFormatFloat64:
            amplitude = 0.0;
            break;
        case pcmFormatInt16:
            amplitude = float(pcmBuffer.pcmData.int16Data[dataOffset]) / 32768.0;
            break;
        case pcmFormatInt32:
            amplitude = float(pcmBuffer.pcmData.int32Data[dataOffset]) / 2147483647.0;
            break;
        default:
            amplitude = 0.0;
            break;
    }
    
    float targetAmplitude = abs(amplitude);
    // 提升低振幅 平均值在 0.06
    if(targetAmplitude <= 0.1){
        targetAmplitude = targetAmplitude * 4;
    } else if (targetAmplitude <= 0.2){
        targetAmplitude = targetAmplitude * 3;
    } else if (targetAmplitude <= 0.3){
        targetAmplitude = targetAmplitude * 2;
    }
    return targetAmplitude;
}

// dance style
float4x4 scaleDance(float amplitude){
    float scale = 0.5 +  amplitude * 300.0;
    
    // 4. 构造缩放矩阵（仅Y轴缩放）
    float4x4 scaleMatrix = float4x4(
                                    1.0, 0.0,   0.0, 0.0,
                                    0.0, scale, 0.0, 0.0,
                                    0.0, 0.0,   1.0, 0.0,
                                    0.0, 0.0,   0.0, 1.0
                                    );
    return scaleMatrix;
}

// 胶囊模型「仅中心拉升、其余位置不变」核心函数
float4 getCapsuleCenterOnlyStretch(float4 originalPos,
                                   float oldAmplitude,
                                   float animationPros, // 0 ~ 1
                                   float targetAmplitude,
                                   float maxCenterStretch) {
    float4 newPos = originalPos;
    
    float x = originalPos.x;
    float y = originalPos.y;
    float z = originalPos.z;
    float w = originalPos.w;
    
    newPos.x = x;
    newPos.z = z;
    newPos.w = w;
    // 新老高度差
    float oldH = y + oldAmplitude * maxCenterStretch;
    float tarH = y + targetAmplitude * maxCenterStretch;
    
    // 达到目标高度保留
    if (targetAmplitude == animationPros) {
        if (y > -0.1 && y < 0.1) {
            newPos.y = y;
        } else {
            if (y > 0) {
                newPos.y = y  +  targetAmplitude  * maxCenterStretch;
            } else  {
                newPos.y = y  -  targetAmplitude  * maxCenterStretch;
            }
        }
        return newPos;
    }
    
    
    // 计算高度差 高度差进度
    float gaingPro = abs(oldH - tarH) * animationPros;
    
    if ((tarH - oldH) < 0){// 判断原始的高度是增加还是减少
        gaingPro = gaingPro * (-1);
    }
    
    if (y > -0.1 && y < 0.1) {
        newPos.y = y;
    } else {
        if (y > 0) {
            newPos.y = y + oldAmplitude * maxCenterStretch + gaingPro;
        } else  {
            newPos.y = y - oldAmplitude * maxCenterStretch - gaingPro;
        }
    }
    
    return newPos;
}

// 上升动画曲线 快速开始
float easeOutAudioWaveformUP(float t) {
    t = CLAMP01(t);
    return t == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t);
}
// 下降动画 慢速度下降
float easeOutAudioWaveformDown(float t) {
    t = CLAMP01(t);
    if (t < 1e-6) return 0.0;
    if (t > 1.0 - 1e-6) return 1.0;
    return 1.0 - pow(2.0, -8.0 * t);
}

// 动画进度
float animationProgress(constant AnimationTimeUniform& animationTime,bool isUP){
    
    float timePro = (animationTime.currentTime - animationTime.startTime) / animationTime.totalDuration; // time (0 ~ 1)
    timePro =  CLAMP01(timePro);
    float animatedPro = 0.0;
    if (isUP){
        animatedPro = easeOutAudioWaveformUP(timePro);
    } else {
        animatedPro = easeOutAudioWaveformDown(timePro);
    }
   
//    return timePro;
    return animatedPro;
}

/*
  animationPros   当前进度
  targetAmplitude 1/44s 不变
  oldAmplitude    1/44s 不变
 
     1/44s                     1/60s                   1/44s
 oldAmplitude ============> animationPros - - - - > targetAmplitude
 */
// 计算着色器 1/60 动画的事实进度 开始->目标高度
kernel void compute_peak_kernel(constant AudioPCMBufferUniforms& pcmBuffer    [[buffer(3)]],
                                device   AnimationProsBuffer& sharePeak       [[buffer(4)]], // 共享
                                constant ComputeUniforms& computeUniforms     [[buffer(5)]],
                                uint thread_index [[thread_position_in_grid]]
                                ) {
    /*
     一个线程对应一个顶点 modelID = 所有model总顶点数 / model顶点数
     多个顶点对应一个model，一个模型只对应一个向量变换
     */
    int modelID = thread_index;
    // 由于PCM是 1/44s 跟新一次 amplitude 在 1/44s 内 amplitude不变
    float amplitude =  normalizationPcmData(pcmBuffer, computeUniforms.pcmFormat, modelID,computeUniforms.modelAllCount);
    sharePeak.targetAmplitude[modelID] = amplitude * 1.0;// targetAmplitude 1/44s 不变和 oldAmplitude 的变动频率一致
    
    bool isUP = amplitude > sharePeak.oldAmplitude[modelID]; // 比上一次高 就是上升动画
    float animationPro = animationProgress(computeUniforms.animationTime,isUP);// 计算动画进度
    sharePeak.animationPros[modelID] = animationPro; // 动画时间进度
}


// 计算着色器  1/44  更新一次,计算峰值
kernel void compute_old_peak_kernel(device   AnimationProsBuffer& sharePeak  [[buffer(4)]], // 共享
                                    uint thread_index [[thread_position_in_grid]]
                                    ) {
    /*
     一个线程对应一个顶点 modelID = 所有model总顶点数 / model顶点数
     多个顶点对应一个model，一个模型只对应一个向量变换
     */
    int modelID = thread_index;
    bool isInit = sharePeak.isInitialized[modelID];
    if (isInit){
        sharePeak.oldAmplitude[modelID] = sharePeak.targetAmplitude[modelID]; // 保存上一次的高度
    } else {
        sharePeak.oldAmplitude[modelID] = 0.0; //首次肯要上升
    }
    sharePeak.isInitialized[modelID] = true;
}




// 顶点着色器 1/60
vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant MainVertexUniforms& mainVertexUniforms [[buffer(2)]],
                             constant AnimationProsBuffer& animationProsBuffer [[buffer(4)]] // 共享
                             ) {
    VertexOut out;
    
    float oldAmplitude = animationProsBuffer.oldAmplitude[in.modelID];
    float animationPros = animationProsBuffer.animationPros[in.modelID];
    float targetAmplitude = animationProsBuffer.targetAmplitude[in.modelID];
    // 计算顶点的偏量
    float4 localPos = getCapsuleCenterOnlyStretch(in.position,oldAmplitude,animationPros,targetAmplitude,mainVertexUniforms.maxCenterStretch);
    //  实例矩阵变换   =   变换矩阵   *  模型矩阵
    float4 worldPos = in.transformMatrix()  * localPos;
    
    // MVP最终变换         变换到2D
    out.position = mainVertexUniforms.mvp * worldPos;
    // 颜色透传
    out.color = in.color;
    return out;
}

// 片元Shader
fragment half4 fragment_main(VertexOut in [[stage_in]]){
    return half4(in.color);
}
