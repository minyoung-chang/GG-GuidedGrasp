//
//  CollisionChecker.swift
//  GuidedGrasp
//
//  Created by Min Young Chang on 5/20/21.
//  Copyright © 2021 Yehor Chernenko. All rights reserved.
//

import Foundation
import KDTree

class CollisionChecker {
    let safeDistance = 0.003
    
    public func checkCollision(map: Array<Point3D> ,at point: Point3D)  -> Bool{
        let tree = KDTree<Point3D>(values:map)
        let nearest = tree.nearest(to: point)!
        
        return nearest.squaredDistance(to: point) <= self.safeDistance
    }
}

public struct Point3D: KDTreePoint{
    var x:Float = 0
    var y:Float = 0
    var z:Float = 0

    public init(_ x: Float, _ y: Float, _ z: Float){
        self.x = x
        self.y = y
        self.z = z
    }

    public static var dimensions = 3
    public func kdDimension(_ dimension: Int) -> Double {
        switch dimension{
            case 0:
                return Double(self.x)
            case 1:
                return Double(self.y)
            case 2:
                return Double(self.z)
            default:
                return 0.0
        }
    }
    public func squaredDistance(to otherPoint: Self) -> Double {
        let x = self.x - otherPoint.x
        let y = self.y - otherPoint.y
        let z = self.z - otherPoint.z
        return Double(x*x + y*y + z*z)
    }

}


