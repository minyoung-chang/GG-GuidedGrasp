//
//  ViewController.swift
//  CoreML-in-ARKit
//
//  Created by Yehor Chernenko on 01.08.2020.
//  Copyright © 2020 Yehor Chernenko. All rights reserved.
//
//import Metal
//import MetalKit


import UIKit
import Vision
import ARKit
import AVFoundation
import Speech
import KDTree

// MARK: - Set up
//class ViewController: UIViewController, MTKViewDelegate {
class ViewController: UIViewController {
    
    var targetObject = "bottle"
    
    var scenePointCloud: Array<Point3D> = Array()
    let collisionChecker = CollisionChecker()
    
    var handPixelX: Float?
    var handPixelY: Float?
    var handWorldPosition: SCNVector3?
    var noHandCount = 5           // to prevent speaking too often while looking for hand
    var handDetectionCount = 0.0   // number of detection to register hand position
    var handRegistered = false
    
    var handler: VNImageRequestHandler?
    
    var objectDetectionService = ObjectDetectionService()
    let throttler = Throttler(minimumDelay: 0.5, queue: .main)
    
    let guidingTool = GuidingTool()
    
    var isLoopShouldContinue = true
    var lastLocation: SCNVector3?
    
    var targetPosition: SCNVector3?     // [x, y, z]
    var currentCameraPosition: SCNVector3?
    var lastCameraPosition: SCNVector3?
    
    var speechSynthesizer = AVSpeechSynthesizer()
    
    var isProcessComplete = false
    
    enum phaseType {
        case scanning
        case guiding
        case complete
    }
    
    var currentPhase: phaseType?
    
    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet weak var sessionInfoLabel: UILabel!
    
    @IBOutlet var resetButton: UIButton!
    
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
    var thumbTip: CGPoint?
    var indexTip: CGPoint?
    
    var middleTip: CGPoint?
    var wristCenter: CGPoint?
    
    
    
    
    let mtdevice: MTLDevice = MTLCreateSystemDefaultDevice()!
    var mtqueue: MTLCommandQueue!
    var mtdepthtex: MTLTexture!
    var mtdepthtexout: MTLTexture!
    var mtdepthbufout: MTLBuffer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.scene = SCNScene()
        
        resetButton.isEnabled = true
        
        // Enable Default Lighting - makes the 3D text a bit poppier.
        sceneView.autoenablesDefaultLighting = true
        
        let audioSession = AVAudioSession.sharedInstance()
        try! audioSession.setCategory(.playback, mode: .default, options: .duckOthers)
        
        mtqueue = mtdevice.makeCommandQueue()!
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // The first phase of the entire process
        self.currentPhase = .scanning
        
        // The screen shouldn't dim during AR experiences.
        UIApplication.shared.isIdleTimerDisabled = true
        startSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopSession()
    }
    
    private func startSession(resetTracking: Bool = false) {
        guard ARWorldTrackingConfiguration.isSupported else {
            assertionFailure("ARKit is not supported")
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.frameSemantics = .sceneDepth
        
        if resetTracking {
            sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            sceneView.session.run(configuration)
        }
    }
    
    func stopSession() {
        sceneView.session.pause()
    }
    
    // MARK: - Core Loop
    func loopProcess() {
        throttler.throttle { [weak self] in
            guard let self = self else { return }
            let message: String
            switch self.currentPhase {
            case .scanning:
                
                message = "Scanning: \(self.targetObject)\n \(self.scenePointCloud.count) points collected"
//                self.textToSpeach(message: message, wait: true)  // annoying!
                AudioServicesPlayAlertSound(1521)   // short
                self.updateMessage(message: message)
                
                if self.isLoopShouldContinue {
                    self.performDetection()
                }
                
                self.loopProcess()
                
            case .guiding:
                self.performGuidance()
                self.loopProcess()
            
            case .complete:
                self.performCompletion()
                self.loopProcess()
                
            case .none:
                print("ERROR OCCURRED")
                
            }
        }
    }
    
    // MARK: - Detecting Phase
    func performDetection() {
        let currentFramePoints = (sceneView.session.currentFrame?.rawFeaturePoints?.points)!
        
        for point in currentFramePoints {
            let kdPoint = Point3D(point[0], point[1], point[2])
            scenePointCloud.append(kdPoint)
        }
        
//        scenePointCloud.append(contentsOf: currentFramePoints)
        
        
        guard let pixelBuffer = sceneView.session.currentFrame?.capturedImage else { return }
        
        
        let depth = self.sceneView.session.currentFrame!.sceneDepth!.depthMap
        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)
        
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: depthWidth, height: depthHeight, mipmapped: false)
        td.usage = .shaderRead
        
        mtdepthtex = mtdevice.makeTexture(descriptor:td)!
        
        let outtd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: depthWidth, height: depthHeight, mipmapped: false)
        outtd.usage = .shaderWrite
        
        mtdepthtexout = mtdevice.makeTexture(descriptor:outtd)!
        mtdepthbufout = mtdevice.makeBuffer(
            length: depthWidth*depthHeight*MemoryLayout<Float>.size,
            options: .storageModeShared
        )!
        
        let buffer = mtqueue.makeCommandBuffer()!
        let c_encoder = buffer.makeComputeCommandEncoder()!
        let mf = mtdevice.makeDefaultLibrary()!.makeFunction(name: "grayscaleKernel")!
        let pipeline = try! mtdevice.makeComputePipelineState(function: mf)
        
        CVPixelBufferLockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))
        mtdepthtex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: mtdepthtex.width, height: mtdepthtex.height, depth: mtdepthtex.depth)), mipmapLevel: 0, withBytes: CVPixelBufferGetBaseAddress(depth)!, bytesPerRow: mtdepthtex.width * MemoryLayout<Float>.size)
        CVPixelBufferUnlockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))
        
        c_encoder.setComputePipelineState(pipeline)
        c_encoder.setTexture(mtdepthtex, index: 0)
        c_encoder.setTexture(mtdepthtexout, index: 1)
        c_encoder.dispatchThreads(MTLSize(
            width: mtdepthtex.width,
            height: mtdepthtex.height,
            depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16,height: 16,depth: 1)
        )
        c_encoder.endEncoding()
        let b_encoder = buffer.makeBlitCommandEncoder()!
        b_encoder.copy(from: mtdepthtexout, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: mtdepthtex.width, height: mtdepthtex.height, depth: mtdepthtex.depth), to: mtdepthbufout, destinationOffset: 0, destinationBytesPerRow: mtdepthtex.width * MemoryLayout<Float>.size, destinationBytesPerImage: mtdepthtex.width * mtdepthtex.height * MemoryLayout<Float>.size)
        b_encoder.endEncoding()
        
        buffer.commit()
        
        objectDetectionService.detect(on: .init(pixelBuffer: pixelBuffer)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                let rectOfInterest = VNImageRectForNormalizedRect(
                    response.boundingBox,
                    Int(self.sceneView.bounds.width),
                    Int(self.sceneView.bounds.height))
                
                if (response.classification.lowercased() == self.targetObject.lowercased()) {
                    
                    buffer.waitUntilCompleted()
                    
                    
                    // add AR Anchor on the object position
                    self.addAnnotation(rectOfInterest: rectOfInterest,
                                       text: response.classification)
                    self.addFeaturePoints(pointCloud: self.scenePointCloud)
                    // Save Camera projection Matrix at this moment
                    let projectionMatrix = self.sceneView.session.currentFrame?.camera.projectionMatrix
                    let viewMatrix = self.sceneView.session.currentFrame?.camera.viewMatrix(for: UIInterfaceOrientation.portrait)
//                    let viewProjectionMatrix = matrix_multiply(projectionMatrix!, viewMatrix!)
////
//                    // Save bounding box of the object at this moment
//                    let minX = Int(response.boundingBox.minX * self.sceneView.bounds.height) //bottom
//                    let maxX = Int(response.boundingBox.maxX * self.sceneView.bounds.height) //top
//
//                    let minY = Int(response.boundingBox.minY * self.sceneView.bounds.width)  // left
//                    let maxY = Int(response.boundingBox.maxY * self.sceneView.bounds.width)  // right
                    
//                    let camDataStr = self.camData2String(minX: minX, maxX: maxX, minY: minY, maxY: maxY, projectionMatrix: viewProjectionMatrix)
//                    let pointCloudStr = self.pointCloud2Str(pointCloud: self.scenePointCloud)
                    
                    let depthMap = self.sceneView.session.currentFrame?.sceneDepth?.depthMap
                    var depthMapFloatArray: Array<[Float32]> = Array()
//
                    if let depth = depthMap{
                        let depthWidth = CVPixelBufferGetWidth(depth)
                        let depthHeight = CVPixelBufferGetHeight(depth)
                        CVPixelBufferLockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))

                        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depth), to: UnsafeMutablePointer<Float32>.self)
                        for x in 0...depthHeight-1{
                            var distancesLine = [Float32]()
                            for y in 0...depthWidth-1{
                                let distanceAtXYPoint = floatBuffer[x * depthWidth + y]
                                distancesLine.append(Float32(distanceAtXYPoint))
                            }
                            depthMapFloatArray.append(distancesLine)
                            print(distancesLine)
                        }
                        CVPixelBufferUnlockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))
                    }
                    
                    print("---")
                    
                    if let depth = depthMap{
                        let depthWidth = CVPixelBufferGetWidth(depth)
                        let depthHeight = CVPixelBufferGetHeight(depth)
                        
                        let minX = Int(response.boundingBox.minX * CGFloat(depthHeight)) //bottom
                        let maxX = Int(response.boundingBox.maxX * CGFloat(depthHeight)) //top

                        let minY = Int(response.boundingBox.minY * CGFloat(depthWidth))  // left
                        let maxY = Int(response.boundingBox.maxY * CGFloat(depthWidth))  // right
                        
                        CVPixelBufferLockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))

                        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depth), to: UnsafeMutablePointer<Float32>.self)
                        for x in minX-10...maxX+10{
                            var distancesLine = [Float32]()
                            for y in minY-10...maxY+10{
                                let distanceAtXYPoint = floatBuffer[x * depthWidth + y]
                                distancesLine.append(Float32(distanceAtXYPoint))
                            }
                            depthMapFloatArray.append(distancesLine)
                            print(distancesLine)
                        }
                        CVPixelBufferUnlockBaseAddress(depth, CVPixelBufferLockFlags(rawValue: 0))
                    }
                    
                    
                    
//

//                    print("--##--")
                    
//                    let activityViewController = UIActivityViewController(activityItems: [camDataStr, pointCloudStr], applicationActivities: nil)
//                    self.present(activityViewController, animated: true, completion: nil)
                    
                }
                
            case .failure(let error):
                print(error)
                break
            }
        }
    }
    
    func addAnnotation(rectOfInterest rect: CGRect, text: String) {
//        let point = CGPoint(x: rect.midX, y: rect.midY)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        
        let scnHitTestResults = sceneView.hitTest(point,
                                                  options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
        guard !scnHitTestResults.contains(where: { $0.node.name == BubbleNode.name }) else { return }
        
        // raycast to any mesh
        guard let raycastQuery = sceneView.raycastQuery(from: point,
                                                        allowing: .estimatedPlane,
                                                        alignment: .any),
              let raycastResult = sceneView.session.raycast(raycastQuery).first else { return }
        
        let position = SCNVector3(raycastResult.worldTransform.columns.3.x,
                                  raycastResult.worldTransform.columns.3.y,
                                  raycastResult.worldTransform.columns.3.z)
        self.targetPosition = position
        guard let cameraPosition = sceneView.pointOfView?.position else { return }
        let distance = (position - cameraPosition).length()
        guard distance <= 0.75 else { return }
        
        let bubbleNode = BubbleNode(text: text, color: UIColor.cyan)
        bubbleNode.worldPosition = position
    
        
        sceneView.prepare([bubbleNode]) { [weak self] success in
            if success {
                self?.sceneView.scene.rootNode.addChildNode(bubbleNode)
                self?.textToSpeach(message: "Scanning Complete.", wait: false)
                self?.currentPhase = .guiding
            }
        }
    }
    
    func addFeaturePoints(pointCloud: Array<Point3D>) {
        guard let targetPosition = targetPosition else {return}
//        for
        for i in 0..<pointCloud.count {
            let point = pointCloud[i]
            let position = SCNVector3(point.x, point.y, point.z)
//            guard let cameraPosition = sceneView.pointOfView?.position else { return }
            
            let distance = (targetPosition - position).length()
            guard distance < 0.1 else { continue }
            
            let depthpixel = sceneView.session.currentFrame!.camera.projectPoint(simd_float3(point.x, point.y, point.z), orientation: .portrait, viewportSize: CGSize(width: mtdepthtex.width, height: mtdepthtex.height))
            let pixvalue = mtdepthbufout.contents().load(fromByteOffset: MemoryLayout<Float>.size * (Int(depthpixel.y) * mtdepthtex.width + Int(depthpixel.x)), as: Float.self)
            let bubbleNode = BubbleNode(text: "", color: UIColor(white: CGFloat(pixvalue), alpha: 1.0) )
            bubbleNode.worldPosition = position
            
            sceneView.prepare([bubbleNode]) { [weak self] success in
                if success {
                    self?.sceneView.scene.rootNode.addChildNode(bubbleNode)
                }
            }
        }
    }
    
    func camData2String(minX: Int, maxX: Int, minY: Int, maxY: Int, projectionMatrix: simd_float4x4) -> String {
        
        var fileToWrite = ""
        let boundingBox = "\(minX) \(maxX) \(minY) \(maxY)"
        fileToWrite += "bottom top left right\n"
        fileToWrite += boundingBox
        fileToWrite += "\r\n"
        fileToWrite += "Projection Matrix\n"
        let col0 = projectionMatrix.columns.0
        let col0_str = "\(col0[0]),\(col0[1]),\(col0[2]),\(col0[3]),"
        let col1 = projectionMatrix.columns.1
        let col1_str = "\(col1[0]),\(col1[1]),\(col1[2]),\(col1[3]),"
        let col2 = projectionMatrix.columns.2
        let col2_str = "\(col2[0]),\(col2[1]),\(col2[2]),\(col2[3]),"
        let col3 = projectionMatrix.columns.3
        let col3_str = "\(col3[0]),\(col3[1]),\(col3[2]),\(col3[3])"        // no "," at the end for the last column
        fileToWrite += col0_str
        fileToWrite += col1_str
        fileToWrite += col2_str
        fileToWrite += col3_str
        
        fileToWrite += "\r\n"
        
        return fileToWrite
    }
    
    func pointCloud2Str(pointCloud: Array<Point3D>) -> String {
        
        // 1
        var fileToWrite = ""
        let headers = ["ply", "format ascii 1.0", "element vertex \(pointCloud.count)", "property float x", "property float y", "property float z", "end_header"]
        for header in headers {
            fileToWrite += header
            fileToWrite += "\r\n"
        }
        
        // 2
        for i in 0..<pointCloud.count {
        
            // 3
            let point = pointCloud[i]
            
            // 5
            let pvValue = "\(point.x) \(point.y) \(point.z)"
            fileToWrite += pvValue
            fileToWrite += "\r\n"
        }
        
        return fileToWrite
    }
    
    // MARK: - Guide Phase
    func performGuidance() {    
        self.detectAndLocalizeHand()
        
        guard let cameraPosition = self.sceneView.pointOfView?.position else { return }
        self.currentCameraPosition = cameraPosition
        
        // Distance based on the Hand Position
        guard let handWorldPosition = self.handWorldPosition else {return}
        let distance = (handWorldPosition - self.targetPosition!).length()
        
        if (distance < 0.12) {   // target object 15 cm away from the camera
            self.currentPhase = .complete
            return
        }
        
        let handWorldPositionPoint3D = Point3D(handWorldPosition.x, handWorldPosition.y, handWorldPosition.z)
        
        let willCollide = collisionChecker.checkCollision(map: self.scenePointCloud, at: handWorldPositionPoint3D)
        
        if willCollide {
            self.updateMessage(message: "CAUTION!")
            textToSpeach(message: "Obstacle approaching", wait: true)
            return
        }
        
        let pixelValues = calculatePixelValues()
        let targetDirection = guidingTool.checkTargetDirection(pixelValues: pixelValues)
        let message = guidingTool.getDirectionMessage(targetDirection: targetDirection, distance: distance)
        
        switch targetDirection {
        case .onScreen:
            if distance < 0.35 {
                AudioServicesPlayAlertSound(1521)   // short
            } else if distance < 0.75 {
                AudioServicesPlayAlertSound(1520)   // medium
            }
            textToSpeach(message: "Go Forward", wait: true)
        case .goUp:
            textToSpeach(message: "Go Up", wait: true)
        case .goDown:
            textToSpeach(message: "Go Down", wait: true)
        case .goLeft:
            textToSpeach(message: "Go Left", wait: true)
        case .goRight:
            textToSpeach(message: "Go Right", wait: true)
        }
        
        self.updateMessage(message: message)
        self.lastCameraPosition = self.currentCameraPosition
    }
    
    // MARK: - Guide Phase - Hand Localization
    func detectAndLocalizeHand() {
        do {
            // Perform VNDetectHumanHandPoseRequest
            try self.handler!.perform([handPoseRequest])
            // Continue only when a hand was detected in the frame.
            // Since we set the maximumHandCount property of the request to 1, there will be at most one observation.
            guard let observation = handPoseRequest.results?.first else {
                self.updateMessage(message: "Hand not on the screen")
                
                if !self.handRegistered {
                    self.handDetectionCount = 0
                }
                
                if self.noHandCount == 0 {
                    self.textToSpeach(message: "Show your hand", wait: false)
                    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate) // long
                    self.noHandCount += 1
                } else {
                    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate) // long
                    self.noHandCount += 1
                    
                    if self.noHandCount > 5 {
                        self.noHandCount = 0
                    }
                }
                return
            }
            
            if self.handDetectionCount < 5.0 && !self.handRegistered {
                if self.handDetectionCount == 0.0 {
                    self.textToSpeach(message: "Registering Hand", wait: false)
                }
                self.handDetectionCount += 1.0
                self.updateMessage(message: "Registering Hand \((self.handDetectionCount / 5.0)*100) %")
                AudioServicesPlayAlertSound(1521)   // short
                return
            }
            
            if self.handDetectionCount == 5.0 {
                self.handDetectionCount += 1.0
                self.textToSpeach(message: "Registration Complete. Start Moving.", wait: false)
                self.noHandCount = 0
                self.handRegistered = true
            }
            
            // Get points for the detected hand
            let handPoints = try observation.recognizedPoints(.all)

            // Look for tip points.
            guard let middleTipPoint = handPoints[.middleTip], let wristPoint = handPoints[.wrist] else {
                return
            }
            
            // Ignore low confidence points.
            guard middleTipPoint.confidence > 0.5 && wristPoint.confidence > 0.5 else {
                return
            }
        
            middleTip = CGPoint(x: middleTipPoint.location.x, y: middleTipPoint.location.y)
            wristCenter = CGPoint(x: wristPoint.location.x, y: wristPoint.location.y)
            
            self.handPixelX = ((Float(wristCenter!.x) + Float(middleTip!.x)) / 2) * Float(sceneView.bounds.height)
            self.handPixelY = ((Float(wristCenter!.y) + Float(middleTip!.y)) / 2) * Float(sceneView.bounds.width)
            
            let handPixelXInt = Int(self.handPixelX!)
            let handPixelYInt = Int(self.handPixelY!)
            let handPoint = CGPoint(x: handPixelYInt, y: handPixelXInt) // X and Y are mixed up..
            self.localizeHand(point: handPoint)
        } catch {
        }
    }
    
    func localizeHand(point: CGPoint) {
        guard let raycastQuery = sceneView.raycastQuery(from: point,
                                                        allowing: .estimatedPlane,
                                                        alignment: .any),
              let raycastResult = sceneView.session.raycast(raycastQuery).first else { return }
        
        let position = SCNVector3(raycastResult.worldTransform.columns.3.x,
                                  raycastResult.worldTransform.columns.3.y,
                                  raycastResult.worldTransform.columns.3.z)
        
        let bubbleNode = BubbleNode(text: "", color: UIColor.magenta)
        bubbleNode.worldPosition = position
        self.handWorldPosition = position
        
        sceneView.prepare([bubbleNode]) { [weak self] success in
            if success {
                self?.sceneView.scene.rootNode.addChildNode(bubbleNode)
            }
        }
        
    }
    
    func calculatePixelValues() -> simd_float4 {
        let targetPosition4 = simd_float4(self.targetPosition!.x, self.targetPosition!.y, self.targetPosition!.z, 1)
        
        let projectionMatrix = self.sceneView.session.currentFrame?.camera.projectionMatrix
        let viewMatrix = self.sceneView.session.currentFrame?.camera.viewMatrix(for: UIInterfaceOrientation.portrait)
        let viewProjectionMatrix = matrix_multiply(projectionMatrix!, viewMatrix!)
        var pixelValues = matrix_multiply(viewProjectionMatrix, targetPosition4)
        
        pixelValues /= pixelValues.z
        pixelValues.x = (pixelValues.x + 1.0) / 2
        pixelValues.y = (pixelValues.y + 1.0) / 2
        
        return pixelValues
    }
    
    // MARK: - Completion Phase
    
    func performCompletion() {
        if isProcessComplete {
            return
        } else {
            isProcessComplete = true
            let message = """
                            Process Complete.
                            \(self.targetObject) in front of the hand.
                            Tap to restart.
                            """
            textToSpeach(message: message, wait: false)
            self.updateMessage(message: message)
        }
    }
    
    // MARK: - Tools
    
    func textToSpeach(message: String, wait: Bool) {
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.4   // speak slower than default (0.5)
        
        if wait {
            if !speechSynthesizer.isSpeaking{
                self.speechSynthesizer.speak(utterance)
            }
        } else {
            self.speechSynthesizer.speak(utterance)
        }
        
    }
    
    func updateMessage(message: String) {
        DispatchQueue.main.async {
            self.sessionInfoLabel.text = message
            self.sessionInfoLabel.isHidden = message.isEmpty
        }
    }
    
    // MARK: - Session Updates

    private func onSessionUpdate(for frame: ARFrame, trackingState: ARCamera.TrackingState) {
        isLoopShouldContinue = false

        // Update the UI to provide feedback on the state of the AR experience.
        let message: String
        
        switch trackingState {
        case .normal where frame.anchors.isEmpty:
            // No planes detected; provide instructions for this app's AR interactions.
            message = "Move the device around to detect horizontal and vertical surfaces."
            
        case .notAvailable:
            message = "Tracking unavailable."
            
        case .limited(.excessiveMotion):
            message = "Tracking limited - Move the device more slowly."
            
        case .limited(.insufficientFeatures):
            message = "Tracking limited - Point the device at an area with visible surface detail, or improve lighting conditions."
            
        case .limited(.initializing):
            self.textToSpeach(message: "Looking for \(self.targetObject)", wait: true )
            self.textToSpeach(message: "Start Scanning.", wait: true )
            message = "Initializing AR session."
            
        default:
            // No feedback needed when tracking is normal and planes are visible.
            // (Nor when in unreachable limited-tracking states.)
            message = ""
            isLoopShouldContinue = true
            loopProcess()
            
        }
        
        sessionInfoLabel.text = message
        sessionInfoLabel.isHidden = message.isEmpty
    }
}

extension ViewController: ARSessionDelegate {
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard let frame = session.currentFrame else { return }
        onSessionUpdate(for: frame, trackingState: camera.trackingState)
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        onSessionUpdate(for: frame, trackingState: frame.camera.trackingState)
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        onSessionUpdate(for: frame, trackingState: frame.camera.trackingState)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = SCNMatrix4(frame.camera.transform)
        let orientation = SCNVector3(-transform.m31, -transform.m32, transform.m33)
        let location = SCNVector3(transform.m41, transform.m42, transform.m43)
        let currentPositionOfCamera = orientation + location
        
        if lastLocation != nil{
            //let speed = (lastLocation - currentPositionOfCamera).length()
            isLoopShouldContinue = sceneView.scene.rootNode.childNodes.count < 30
        }
        lastLocation = currentPositionOfCamera
        
        //Hand pose calculation
        self.handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .up, options: [:])
        
    }
    
    
    // MARK: - ARSessionObserver
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay.
        sessionInfoLabel.text = "Session was interrupted"
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required.
        sessionInfoLabel.text = "Session interruption ended"
        startSession(resetTracking: true)
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionInfoLabel.text = "Session error: \(error.localizedDescription)"
    }
}

extension ViewController: ARSCNViewDelegate { }
