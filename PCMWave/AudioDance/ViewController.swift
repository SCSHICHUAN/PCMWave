//
//  ViewController.swift
//  PCMWave
//
//  Created by Stan on 2026/1/17.
//

import UIKit


class ViewController: UIViewController {

    private var pcmPlayer: AudioPCMPlayer!
    let waveView = WaveDanceMLView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 初始化播放器
        pcmPlayer = AudioPCMPlayer()
        
        // 播放本地音频文件（替换成你的音频文件路径！）
        // 方式1：工程内的音频文件（如test.mp3，需加入Copy Bundle Resources）

        
        // 方式2：沙盒路径（如Documents目录下的音频）
        // let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        // let audioPath = "\(documentsPath)/test.mp3"
        
        // 开始播放并提取PCM
        pcmPlayer.playAudioAndGetPCM(filePath: "/Users/stan/Downloads/ScreenRecording_01-17-2026 15-18-44_1.MP4")
//        pcmPlayer.playAudioAndGetPCM(filePath: "/Users/stan/Documents/视频剪辑/音乐src/beautiful_mistakes.mp3")
        waveView.frame = view.bounds
        view.addSubview(waveView)
        waveView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            waveView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            waveView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            waveView.topAnchor.constraint(equalTo: view.topAnchor),
            waveView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pcmPlayer.pcmCome = { [weak self] buffer  in
            guard let self else { return }
            self.waveView.pushPCMtoGPU(buffer: buffer, count: 4096)
        }
        
        // 控制按钮
        cameraControl()
    }
    
    // 如需停止播放，可调用
    @IBAction func stopButtonTapped(_ sender: UIButton) {
        pcmPlayer.stopPlayback()
    }

    
    
    
    
    
    
    private let moveSpeed: Float = 0.1 // 单次移动步长（调小更顺滑）
    private let rotateSpeed: Float = 0.5 // 单次旋转步长
    private let scrollSpeed: Float = 0.5 // 单次缩放步长
    
    // 记录按钮按下状态
    private var pressedBtnTags: Set<Int> = []
    // 持续更新的定时器（和屏幕刷新率同步）
    private var displayLink: CADisplayLink!

    
    // 页面销毁时释放定时器
    deinit {
        displayLink.invalidate()
    }
}


extension ViewController {
  
    
      func cameraControl() {
        
        
    
        
        // 2. 添加控制按钮
        setupCameraButtons()
        
        // 3. 初始化持续更新的定时器
        setupDisplayLink()
    }
    
    // MARK: - 初始化屏幕刷新率定时器
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateCameraContinuously))
        displayLink.add(to: .main, forMode: .common)
        displayLink.isPaused = true // 初始暂停，有按钮按下时再启动
    }
    
    // MARK: - 持续更新相机状态（每帧调用）
    @objc private func updateCameraContinuously() {
        guard !pressedBtnTags.isEmpty else {
            displayLink.isPaused = true // 没有按钮按下时暂停
            return
        }
        
        let camera = waveView.camera
        camera.movementSpeed = 50
        
        // 遍历所有按下的按钮，持续更新相机
        for tag in pressedBtnTags {
            switch tag {
            case 1001: camera.processKeyboard(.forward, deltaTime: moveSpeed)
            case 1002: camera.processKeyboard(.backward, deltaTime: moveSpeed)
            case 1003: camera.processKeyboard(.left, deltaTime: moveSpeed)
            case 1004: camera.processKeyboard(.right, deltaTime: moveSpeed)
            case 1005: camera.processMouseMovement(xOffset: -rotateSpeed, yOffset: 0)
            case 1006: camera.processMouseMovement(xOffset: rotateSpeed, yOffset: 0)
            case 1007: camera.processMouseScroll(scrollSpeed)
            case 1008: camera.processMouseScroll(-scrollSpeed)
            default: break
            }
        }
        
        // 实时刷新渲染
        waveView.refreshRender()
    }
    
    // MARK: - 创建按钮（适配所有屏幕）
    private func setupCameraButtons() {
        let btnTitles = ["前进", "后退", "左移", "右移", "左转", "右转", "放大", "缩小"]
        let btnTags = [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008]
        
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        // 创建按钮（添加按下/抬起事件）
        for (index, title) in btnTitles.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(title, for: .normal)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = .black.withAlphaComponent(0.7)
            btn.layer.cornerRadius = 8
            btn.clipsToBounds = true
            btn.tag = btnTags[index]
            
            // 按钮按下事件（touchDown）
            btn.addTarget(self, action: #selector(btnPressDown(_:)), for: .touchDown)
            // 按钮抬起事件（包含松手、离开按钮、取消）
            btn.addTarget(self, action: #selector(btnPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            
            btn.widthAnchor.constraint(equalToConstant: 60).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 40).isActive = true
            stack.addArrangedSubview(btn)
        }
        
        // 按钮约束：右侧+垂直居中
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        view.bringSubviewToFront(stack)
    }
    
    // MARK: - 按钮按下：记录状态+启动定时器
    @objc private func btnPressDown(_ sender: UIButton) {
        pressedBtnTags.insert(sender.tag)
        displayLink.isPaused = false // 启动持续更新
    }
    
    // MARK: - 按钮抬起：移除状态+无按钮时暂停定时器
    @objc private func btnPressUp(_ sender: UIButton) {
        pressedBtnTags.remove(sender.tag)
        if pressedBtnTags.isEmpty {
            displayLink.isPaused = true // 没有按钮按下时暂停
        }
    }
    
    
}
