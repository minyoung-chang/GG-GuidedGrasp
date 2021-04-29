
import Foundation
import CoreMotion

/**
    Construct an instance of this class at calibration
*/
public class DisplacementVectorCalculator{
    var pitch0: Double! = 0.0
    var roll0 = 0.0, yaw0: Double = 0.0
    var velocityx = 0.0, velocityy = 0.0, velocityz: Double = 0.0

    /**
	Constructs and calibrates the calculator with the device state
	@param deviceMotion the current state of the device's motion
    */
    
    func initiate(deviceMotion: CMDeviceMotion)
    {
        pitch0 = degrees(radians: deviceMotion.attitude.pitch)
        roll0 = degrees(radians: deviceMotion.attitude.roll)
        yaw0 = degrees(radians: deviceMotion.attitude.yaw)
        velocityx = 0.0
        velocityy = 0.0
        velocityz = 0.0
    }
    /**
        Calculates the displacement of iPhone based on the current motion state of the device and the seconds elapsed since last retrieval (call this method frequently for more accuracy)
        @param deviceMotion current instance of CMDeviceMotion
	@param timeInterval seconds elapsed since last retrieval (if no retrieval has been made, then this is seconds since construction/calibration)
	@return vector noting the approximate rectangular displacement of the phone since last retrieval
     */
    
    
    func getDisplacementVector(deviceMotion: CMDeviceMotion, timeInterval: Double) -> ThreeDRectangularVector
    {
        let x, y, z: ThreeDRectangularVector
        var pitch, roll, yaw: Double
        pitch = degrees(radians: deviceMotion.attitude.pitch) - pitch0
        roll = degrees(radians: deviceMotion.attitude.roll) - roll0
        yaw = degrees(radians: deviceMotion.attitude.yaw) - yaw0
        velocityx += deviceMotion.userAcceleration.x * timeInterval * 9.81
        velocityy += deviceMotion.userAcceleration.y * timeInterval * 9.81
        velocityz += deviceMotion.userAcceleration.z * timeInterval * 9.81
        x = ThreeDRectangularVector(p: velocityx * timeInterval, eulerAngle: yaw, eulerAngle1: roll)
        y = ThreeDRectangularVector(p: velocityy * timeInterval, eulerAngle: pitch, eulerAngle1: yaw)
        z = ThreeDRectangularVector(p: velocityz * timeInterval, eulerAngle: roll, eulerAngle1: pitch)
        return x + y + z;
    }
}

/**
    Stores three dimensional vector or point that can be operated on with +, -, *, / as usual
*/
public class ThreeDRectangularVector
{
    var x, y, z: Double
    init()
    {
        x = 0.0;
        y = 0.0;
        z = 0.0;
    }
    init(x: Double, y: Double, z: Double)
    {
        self.x = x
        self.y = y
        self.z = z
    }
    init(p: Double, eulerAngle: Double, eulerAngle1: Double)
    {
        var phi, theta: Double
        phi = eulerAngle
        theta = eulerAngle1
        if(phi < 0)
        {
            phi *= -1
            theta = 360 - theta
        }
        else if(phi > 180)
        {
            phi = 360 - phi
	theta = 360 - theta
        }
        if(theta < 0)
        {
            theta += 360
        }
        else if(theta > 360)
        {
            theta -= 360
        }
        x = p * sin(phi) * cos(theta)
        y = p * sin(phi) * sin(theta)
        z = p * cos(phi)
		
    }
}

func +(left: ThreeDRectangularVector, right: ThreeDRectangularVector) -> ThreeDRectangularVector
{
    return ThreeDRectangularVector(x: left.x + right.x, y: left.y + right.y, z: left.z + right.z)
}
func -(left: ThreeDRectangularVector, right: ThreeDRectangularVector) -> ThreeDRectangularVector
{
    return ThreeDRectangularVector(x: left.x - right.x, y: left.y - right.y, z: left.z - right.z)
}
func *(left: ThreeDRectangularVector, right: ThreeDRectangularVector) -> ThreeDRectangularVector
{
    return ThreeDRectangularVector(x: left.x * right.x, y: left.y * right.y, z: left.z * right.z)
}
func /(left: ThreeDRectangularVector, right: ThreeDRectangularVector) -> ThreeDRectangularVector 
{
    return ThreeDRectangularVector(x: left.x / right.x, y: left.y / right.y, z: left.z / right.z)
}
func degrees(radians: Double) -> Double
{
    return 180 * radians/Double.pi
}
