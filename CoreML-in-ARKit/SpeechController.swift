/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The root view controller that provides a button to start and stop recording, and which displays the speech recognition results.
*/

import UIKit
import Speech

public class SpeechController: UIViewController, SFSpeechRecognizerDelegate {
    // MARK: Properties
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioEngine = AVAudioEngine()
    
    private let speechSynth = AVSpeechSynthesizer()
    
    @IBOutlet var textView: UITextView!
    
    @IBOutlet var recordButton: UIButton!
    
    @IBAction func myUnwindAction(unwindSegue: UIStoryboardSegue){
        
    }
    
    // MARK: View Controller Lifecycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // Disable the record buttons until authorization has been granted.
        recordButton.isEnabled = false
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        
        speechSynth.speak(AVSpeechUtterance(string: "Press and hold down on the screen to record the target object"))
        
        // Configure the SFSpeechRecognizer object already
        // stored in a local member variable.
        speechRecognizer.delegate = self
        
        // Asynchronously make the authorization request.
        SFSpeechRecognizer.requestAuthorization { authStatus in

            // Divert to the app's main thread so that the UI
            // can be updated.
            OperationQueue.main.addOperation {
                switch authStatus {
                case .authorized:
                    self.recordButton.isEnabled = true
                    
                case .denied:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("User denied access to speech recognition", for: .disabled)
                    
                case .restricted:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("Speech recognition restricted on this device", for: .disabled)
                    
                case .notDetermined:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("Speech recognition not yet authorized", for: .disabled)
                    
                default:
                    self.recordButton.isEnabled = false
                }
            }
        }
    }
    
    private func startRecording() throws {
        
        // Cancel the previous task if it's running.
        recognitionTask?.cancel()
        self.recognitionTask = nil
        
        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let inputNode = audioEngine.inputNode

        // Create and configure the speech recognition request.
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
        recognitionRequest.shouldReportPartialResults = false
        
        // Keep speech recognition data on device
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = false
        }
        
        // Create a recognition task for the speech recognition session.
        // Keep a reference to the task so that it can be canceled.
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            
            if let result = result {
                // Update the text view with the results.
                self.textView.text = result.bestTranscription.formattedString
                print("Text \(result.bestTranscription.formattedString)")
                var foundobj = false
                for word in result.transcriptions {
                    if word.formattedString.lowercased() == "bottle"
                        || word.formattedString.lowercased() == "cup"{
                        
                        self.performSegue(withIdentifier: "speakword", sender: word.formattedString)
                        foundobj = true
                        break
                    }
                }
                
                
                // Stop recognizing speech if there is a problem.
                self.audioEngine.stop()
                
                inputNode.removeTap(onBus: 0)

                self.recognitionRequest = nil
                self.recognitionTask = nil

                self.recordButton.isEnabled = true
                self.recordButton.setTitle("Start Recording", for: [])
                
                if (!foundobj) {
                    self.speechSynth.speak(AVSpeechUtterance(string: "Can you repeat that"))
                    
                }
            }
            
            
            
            
        }

        // Configure the microphone input.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Let the user know to start talking.
        textView.text = "(Go ahead, I'm listening)"
        
        
    }
    
    // MARK: SFSpeechRecognizerDelegate
    
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available {
            recordButton.isEnabled = true
            recordButton.setTitle("Start Recording", for: [])
        } else {
            recordButton.isEnabled = false
            recordButton.setTitle("Recognition Not Available", for: .disabled)
        }
    }
    
    public override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        let dst = segue.destination as! ViewController
        dst.targetObject = sender as! String
    }
    
    // MARK: Interface Builder actions
    
    @IBAction func recordButtonTapped() {
        
        do {
            try startRecording()
            recordButton.setTitle("Stop Recording", for: [])
        } catch {
            recordButton.setTitle("Recording Not Available", for: [])
        }
        
    }
    
    @IBAction func recordButtonUntapped() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recordButton.isEnabled = false
        recordButton.setTitle("Stopping", for: .disabled)
        let audioSession = AVAudioSession.sharedInstance()
        try! audioSession.setCategory(.playback, mode: .default, options: .duckOthers)
        
        speechSynth.speak(AVSpeechUtterance(string: "Please wait"))
    }
}

