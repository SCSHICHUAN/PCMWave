//
//  GLM.swift
//  MyMetal
//
//  Created by Stan on 2025/12/7.
//

/*
 GLM 中：MVP = Model * View * Projection  行主序
 Metal 中：MVP = Projection * View * Model 列主序
 GLM 的透视矩阵输出 Z 范围是 [-1, 1]，而 Metal 要求 [0, 1]
 */

import Foundation
import simd

// MARK: - 常用数学函数 (GLM风格)
@inline(__always)
func radians(_ degrees: Float) -> Float {
    return degrees * (.pi / 180)
}

// MARK: - 向量操作
@inline(__always)
func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    simd_normalize(v)
}

@inline(__always)
func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    simd_cross(a, b)
}

@inline(__always)
func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_dot(a, b)
}

// MARK: - 矩阵扩展 (完全等效 GLM)
extension float4x4 {
    // MARK: - 单位矩阵
    static func identity() -> float4x4 {
        matrix_identity_float4x4
    }

    // MARK: - 透视投影 (glm::perspective)
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let tanHalfFovy = tan(fovY / 2.0)
        let invRange = 1.0 / (near - far)
        return float4x4(
            SIMD4<Float>(1 / (aspect * tanHalfFovy), 0, 0, 0),
            SIMD4<Float>(0, 1 / tanHalfFovy, 0, 0),
            SIMD4<Float>(0, 0, (far + near) * invRange, -1),
            SIMD4<Float>(0, 0, 2 * far * near * invRange, 0)
        )
    }

    // MARK: - LookAt 视图矩阵 (glm::lookAt)
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(center - eye) // Forward
        let s = normalize(cross(f, up)) // Right
        let u = cross(s, f) // Up

        let translate = float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-eye.x, -eye.y, -eye.z, 1)
        )

        let rotate = float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        return rotate * translate
    }

    // MARK: - 平移 (glm::translate)
    static func translate(_ v: SIMD3<Float>) -> float4x4 {
        float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(v.x, v.y, v.z, 1)
        )
    }

    // MARK: - 缩放 (glm::scale)
    static func scale(_ v: SIMD3<Float>) -> float4x4 {
        float4x4(
            SIMD4<Float>(v.x, 0, 0, 0),
            SIMD4<Float>(0, v.y, 0, 0),
            SIMD4<Float>(0, 0, v.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    // MARK: - 旋转 (glm::rotate)
    // GLM.swift 中替换 rotate 方法
    static func rotate(angle: Float, axis: SIMD3<Float>) -> float4x4 {
        let a = normalize(axis)
        let x = a.x, y = a.y, z = a.z
        let c = cos(angle)
        let s = sin(angle)
        let t = 1 - c

        // Metal 列主序旋转矩阵（Y轴旋转专用，更简单不易错）
        if axis.x == 0, axis.y == 1, axis.z == 0 {
            return float4x4(
                SIMD4<Float>(c, 0, s, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-s, 0, c, 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
        }

        // 通用旋转矩阵（保留，适配其他轴）
        return float4x4(
            SIMD4<Float>(t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0),
            SIMD4<Float>(t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0),
            SIMD4<Float>(t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
