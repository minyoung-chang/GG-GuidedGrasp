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

// MARK: Set up
//class ViewController: UIViewController, MTKViewDelegate {
class ViewController: UIViewController {
    var scenePointCloud: Array<vector_float3> = Array()
    
    var handPixelX: Float?
    var handPixelY: Float?
    var handWorldPosition: SCNVector3?
    
    var handler: VNImageRequestHandler?
    
    var objectDetectionService = ObjectDetectionService()
    let throttler = Throttler(minimumDelay: 0.5, queue: .global(qos: .userInteractive))
    
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
    let targetObject = "cup"
    
    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet weak var sessionInfoLabel: UILabel!
    
    
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
    var thumbTip: CGPoint?
    var indexTip: CGPoint?
    
    override func viewDidLoad() {
        super.viewDidLoad()
//        checkPermissions()
        
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.scene = SCNScene()
        
        // Enable Default Lighting - makes the 3D text a bit poppier.
        sceneView.autoenablesDefaultLighting = true
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
                
                message = "Scanning: \(self.targetObject)"
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
        scenePointCloud.append(contentsOf: currentFramePoints)
        print(currentFramePoints.count, scenePointCloud.count)
        
        guard let pixelBuffer = sceneView.session.currentFrame?.capturedImage else { return }
        
        objectDetectionService.detect(on: .init(pixelBuffer: pixelBuffer)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                let rectOfInterest = VNImageRectForNormalizedRect(
                    response.boundingBox,
                    Int(self.sceneView.bounds.width),
                    Int(self.sceneView.bounds.height))
                
                if (response.classification == self.targetObject) {
                    self.addAnnotation(rectOfInterest: rectOfInterest,
                                       text: response.classification)
                }
                
            case .failure(let error):
                print(error)
                break
            }
        }
    }
    
    func addAnnotation(rectOfInterest rect: CGRect, text: String) {
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
        
        guard let cameraPosition = sceneView.pointOfView?.position else { return }
        let distance = (position - cameraPosition).length()
        guard distance <= 0.75 else { return }
        
        let bubbleNode = BubbleNode(text: text, color: UIColor.cyan)
        bubbleNode.worldPosition = position
        
        sceneView.prepare([bubbleNode]) { [weak self] success in
            if success {
                self?.sceneView.scene.rootNode.addChildNode(bubbleNode)
                
                self?.targetPosition = position
                self?.textToSpeach(message: "Scanning Complete.", wait: true )
                self?.currentPhase = .guiding
            }
        }
    }
    
    // MARK: - Guide Phase
    func performGuidance() {    
        self.detectAndLocalizeHand()
        
        guard let cameraPosition = self.sceneView.pointOfView?.position else { return }
        self.currentCameraPosition = cameraPosition
        
        // Distance based on the Camera Position
//        let distance = (cameraPosition - self.targetPosition!).length()
        
        // Distance based on the Hand Position
        guard let handWorldPosition = self.handWorldPosition else {return}
        let distance = (handWorldPosition - self.targetPosition!).length()
        
        if (distance < 0.1) {   // target object 10 cm away from the camera
            self.currentPhase = .complete
            return
        }
        
        let pixelValues = calculatePixelValues()
        let targetDirection = guidingTool.checkTargetDirection(pixelValues: pixelValues)
        let message = guidingTool.getDirectionMessage(targetDirection: targetDirection, distance: distance)
        
        switch targetDirection {
        case .onScreen:
            if distance < 0.45 {
                AudioServicesPlayAlertSound(1521)   // short
            } else if distance < 0.65 {
                AudioServicesPlayAlertSound(1520)   // medium
            } else {
                AudioServicesPlayAlertSound(kSystemSoundID_Vibrate) // long
            }
            
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
    
    func detectAndLocalizeHand() {
        do {
            // Perform VNDetectHumanHandPoseRequest
            try self.handler!.perform([handPoseRequest])
            // Continue only when a hand was detected in the frame.
            // Since we set the maximumHandCount property of the request to 1, there will be at most one observation.
            guard let observation = handPoseRequest.results?.first else {
                return
            }
            
            // Get points for thumb and index finger.
            let thumbPoints = try observation.recognizedPoints(.thumb)
            let indexFingerPoints = try observation.recognizedPoints(.indexFinger)
            
            // Look for tip points.
            guard let thumbTipPoint = thumbPoints[.thumbTip], let indexTipPoint = indexFingerPoints[.indexTip] else {
                return
            }
            
            // Ignore low confidence points.
            guard thumbTipPoint.confidence > 0.5 && indexTipPoint.confidence > 0.5 else {
                return
            }
            
            thumbTip = CGPoint(x: thumbTipPoint.location.x, y: thumbTipPoint.location.y)
//            indexTip = CGPoint(x: indexTipPoint.location.x, y: indexTipPoint.location.y)
            
            self.handPixelX = Float(thumbTip!.x) * Float(sceneView.bounds.height)
            self.handPixelY = Float(thumbTip!.y) * Float(sceneView.bounds.width)
    
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
//                self?.sceneView.scene.rootNode.replaceChildNode(bubbleNode, with: bubbleNode)
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
                            \(self.targetObject) in front of the camera.
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
            message = "Initializing AR session."
            
        default:
            // No feedback needed when tracking is normal and planes are visible.
            // (Nor when in unreachable limited-tracking states.)
            message = ""
            isLoopShouldContinue = true
            self.textToSpeach(message: "Looking for \(self.targetObject)", wait: true )
            self.textToSpeach(message: "Start Scanning.", wait: true )
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
        
        if let lastLocation = lastLocation {
            let speed = (lastLocation - currentPositionOfCamera).length()
            isLoopShouldContinue = speed < 0.0025   // default 0.0025
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
