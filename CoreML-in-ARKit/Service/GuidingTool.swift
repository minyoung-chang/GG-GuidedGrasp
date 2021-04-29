////
////  GuidingPhase.swift
////  CoreML-in-ARKit
////
////  Created by Min Young Chang on 4/28/21.
////  Copyright © 2021 Yehor Chernenko. All rights reserved.
////
//
import Foundation
import AVFoundation

class GuidingTool {
    enum targetDirection {
        case onScreen
        case goUp
        case goDown
        case goLeft
        case goRight
    }

    func getDirectionMessage(targetDirection: targetDirection, distance: Float) -> String {
        switch targetDirection {
        case .onScreen:
            return """
                    on Screen
                    \(round(distance * 100) / 100.0) m
                    """
        case .goUp:
            return "go Up"
        case .goDown:
            return "go Down"
        case .goLeft:
            return "go Left"
        case .goRight:
            return "go Right"
        }
    }
    
    func checkTargetDirection(pixelValues: simd_float4) -> targetDirection {
        if ((pixelValues.x >= 0.2) && (pixelValues.x <= 0.8) && (pixelValues.y >= 0.1) && (pixelValues.y <= 0.9)) {
            return .onScreen
        } else if (pixelValues.x < 0.2) {
            return .goLeft
        } else if (pixelValues.x > 0.8) {
            return .goRight
        } else if (pixelValues.y < 0.2) {
            return .goDown
        } else {
            return .goUp
        }
    }
}
