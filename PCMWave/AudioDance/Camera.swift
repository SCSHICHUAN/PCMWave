//
//  Camera.swift
//  MyMetal
//
//  Created by Stan on 2025/12/7.
//

import Foundation
import simd

// MARK: - 相机移动方向与 C++ 保持一致
enum CameraMovement {
    case forward
    case backward
    case left
    case right
    case upward
    case downward
}

// MARK: - Camera 类 (Metal 版，等价 C++ GLM 相机)
class Camera {
    // -----------------------------------------------

    // MARK: - 相机属性
    // -----------------------------------------------

    var position: SIMD3<Float>
    var front: SIMD3<Float> = .init(0, 0, -1)
    var up: SIMD3<Float>
    var right: SIMD3<Float>
    var worldUp: SIMD3<Float>

    // 欧拉角
    var yaw: Float
    var pitch: Float

    // 相机参数
    public var movementSpeed: Float = 2.5
    var mouseSensitivity: Float = 0.1
    var zoom: Float = 45.0

    // -----------------------------------------------

    // MARK: - 初始化（核心修改：固定参数，注释updateCameraVectors）
    // -----------------------------------------------
    // Camera.swift 初始化方法（最终通用版）
    init(position: SIMD3<Float> = SIMD3<Float>(0, 0, 5),
         up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
         yaw: Float = -90.0,
         pitch: Float = 0.0) {
        self.position = position
        self.worldUp = up
        self.yaw = yaw
        self.pitch = pitch
        self.up = up
        self.right = SIMD3<Float>(1, 0, 0)
        updateCameraVectors() // 恢复这行，支持动态更新
    }

    // -----------------------------------------------

    // MARK: - 获取 View 矩阵 (glm::lookAt)
    // -----------------------------------------------
    func getViewMatrix() -> simd_float4x4 {
        let center = position + front
        return float4x4.lookAt(eye: position, center: center, up: up)
    }

    // -----------------------------------------------

    // MARK: - 键盘移动
    // -----------------------------------------------
    func processKeyboard(_ direction: CameraMovement, deltaTime: Float) {
        let velocity = movementSpeed * deltaTime

        switch direction {
        case .forward:
            position += front * velocity
        case .backward:
            position -= front * velocity
        case .left:
            position -= right * velocity
        case .right:
            position += right * velocity
        case .upward:
            position += up * velocity
        case .downward:
            position -= up * velocity
        }
    }

    // -----------------------------------------------

    // MARK: - 鼠标旋转
    // -----------------------------------------------
    func processMouseMovement(xOffset: Float, yOffset: Float, constrainPitch: Bool = true) {
        let x = xOffset * mouseSensitivity
        let y = yOffset * mouseSensitivity

        yaw += x
        pitch += y

        if constrainPitch {
            if pitch > 89.0 { pitch = 89.0 }
            if pitch < -89.0 { pitch = -89.0 }
        }

        updateCameraVectors()
    }

    // -----------------------------------------------

    // MARK: - 鼠标滚轮缩放
    // -----------------------------------------------
    func processMouseScroll(_ yOffset: Float) {
        zoom -= yOffset
        if zoom < 1.0 { zoom = 1.0 }
//        if zoom > 45.0 { zoom = 45.0 }
    }

    // -----------------------------------------------

    // MARK: - 更新摄像机向量 (等价 GLM 版本)
    // -----------------------------------------------
    private func updateCameraVectors() {
        // 前向量
        var f = SIMD3<Float>()
        f.y = sin(radians(pitch))
        f.x = cos(radians(pitch)) * cos(radians(yaw))
        f.z = cos(radians(pitch)) * sin(radians(yaw))

        front = normalize(f)

        // 右向量
        right = normalize(cross(front, worldUp))

        // 上向量
        up = normalize(cross(right, front))
    }
}
