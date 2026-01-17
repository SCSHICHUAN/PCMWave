//
//  EnginePlayer.swift
//  PCMWave
//
//  Created by Stan on 2026/1/17.
//

import UIKit
import AVFoundation

class AudioPCMPlayer: NSObject, AVAudioPlayerDelegate {
    // 音频引擎核心对象
    private var audioEngine: AVAudioEngine!
    private var audioFile: AVAudioFile!
    private var audioPlayerNode: AVAudioPlayerNode!
    public var pcmCome:(AVAudioPCMBuffer)->Void = {_ in }
    
    // 播放指定音频文件，并实时获取PCM数据
    func playAudioAndGetPCM(filePath: String) {
        // 1. 初始化音频会话（必须，否则可能无声音/拿不到数据）
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("音频会话初始化失败：\(error)")
            return
        }
        
        // 2. 加载本地音频文件（支持MP3/WAV/M4A等常见格式）
        let fileURL = URL(string: filePath) ?? URL(fileURLWithPath: filePath)
        
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            print("加载音频文件失败：\(error)")
            return
        }
        
        // 3. 初始化音频引擎和播放节点
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        
        audioEngine.attach(audioPlayerNode)
        
        // 4. 关键：挂载Tap监听PCM数据（播放时实时回调）
        let outputFormat = audioFile.processingFormat
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: outputFormat)
        
        // 挂载PCM数据监听Tap
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            // 核心：这里拿到的就是播放中的原始PCM数据！
//            self.handlePCMData(buffer: buffer, time: time)
            self.pcmCome(buffer)
        }
        
        // 5. 启动引擎并播放音频
        do {
            try audioEngine.start()
            audioPlayerNode.scheduleFile(audioFile, at: nil) {
                // 播放完成回调
                print("音频播放完成")
                self.audioEngine.stop()
                self.audioPlayerNode.removeTap(onBus: 0)
            }
            audioPlayerNode.play()
            print("开始播放音频，并实时提取PCM数据...")
        } catch {
            print("播放音频失败：\(error)")
        }
    }
    
    // 处理实时拿到的PCM数据（核心方法，可自定义逻辑）
//    private func handlePCMData(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // 1. PCM数据基础信息
//        let channelCount = Int(buffer.format.channelCount)
//        let sampleRate = Float(buffer.format.sampleRate)
//        let sampleCount = Int(buffer.frameLength)
//        let bitDepth = buffer.format
        
//        print("📤 实时PCM数据 - 声道数：\(channelCount) | 采样率：\(sampleRate)Hz | 采样点数：\(sampleCount) | 位深：\(bitDepth)bit")
        
        // 2. 读取PCM原始数据（以单声道为例，立体声可遍历channels）
//        if let channelData = buffer.floatChannelData?[0] {
//            // PCM数据是Float类型（范围：-1.0 ~ 1.0），可转换为16bit整数（-32768 ~ 32767）
//            let pcm16Data = UnsafeBufferPointer(start: channelData, count: sampleCount).map {
//                Int16($0 * 32767)
//            }
//
//            // 示例：打印前10个PCM数值（验证数据）
//            let showCount = min(10, sampleCount)
//            print("   前\(showCount)个PCM数值：\(pcm16Data[0..<showCount])")
//
//            // ========== 这里可以添加你的逻辑 ==========
//            // 如：保存PCM数据到文件、实时分析、网络传输等
//            // =======================================
//        }
//    }
    
    // 停止播放
    func stopPlayback() {
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode?.removeTap(onBus: 0)
        print("音频播放已停止")
    }
}


