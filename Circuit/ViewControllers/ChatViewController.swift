import AVFoundation
import FoundationModels
import Speech
import UIKit

final class ChatViewController: UIViewController {
    private let dogImageView = UIImageView()
    private let statusLabel = UILabel()
    private let transcriptLabel = UILabel()
    
    private let wakeWord = "corgi"
    
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var hasInstalledInputTap = false
    private var hasBootstrappedVoiceAssistant = false
    private var isAwaitingPromptAfterWakeWord = false
    private var isListening = false
    private var isGeneratingResponse = false
    private var responseTask: Task<Void, Never>?
    
    @available(iOS 26.0, *)
    private lazy var languageModel = SystemLanguageModel.default
    
    @available(iOS 26.0, *)
    private lazy var languageModelSession: LanguageModelSession? = {
        guard languageModel.isAvailable else { return nil }
        return LanguageModelSession(
            model: languageModel,
            instructions: "You are Corgi, a concise and friendly voice assistant. Keep spoken responses short and useful."
        )
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        synthesizer.delegate = self
        
        // Navigation bar hidden
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasBootstrappedVoiceAssistant else { return }
        hasBootstrappedVoiceAssistant = true
        bootstrapVoiceAssistant()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopListening()
    }
    
    deinit {
        responseTask?.cancel()
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
    }
    
    private func configureView() {
        view.backgroundColor = .systemBackground
        
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.text = ""
        
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptLabel.numberOfLines = 0
        transcriptLabel.textAlignment = .center
        transcriptLabel.font = .preferredFont(forTextStyle: .body)
        transcriptLabel.textColor = .secondaryLabel
        transcriptLabel.text = ""
        
        dogImageView.translatesAutoresizingMaskIntoConstraints = false
        dogImageView.image = UIImage(named: "dog") ?? UIImage(systemName: "pawprint.fill")
        dogImageView.contentMode = .scaleAspectFit
        dogImageView.clipsToBounds = true
        dogImageView.layer.cornerRadius = 14
        
        view.addSubview(statusLabel)
        view.addSubview(dogImageView)
        view.addSubview(transcriptLabel)
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            dogImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dogImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dogImageView.widthAnchor.constraint(equalToConstant: 300),
            dogImageView.heightAnchor.constraint(equalToConstant: 300),
            
            transcriptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            transcriptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            transcriptLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }
    
    private func bootstrapVoiceAssistant() {
        Task { [weak self] in
            guard let self else { return }
            
            let hasPermission = await requestPermissions()
            guard hasPermission else { return }
            
            await MainActor.run {
                self.startListening()
            }
        }
    }
    
    private func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        
        guard speechAuth == .authorized else { return false }
        
        let micAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        
        return micAllowed
    }
    
    private func startListening() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }
        
        stopListening()
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord,
                                         mode: .voiceChat,
                                         options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        hasInstalledInputTap = true
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopListening()
            return
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            
            if let result {
                DispatchQueue.main.async {
                    let transcript = result.bestTranscription.formattedString
                    self.transcriptLabel.text = transcript
                    self.handleTranscript(transcript, isFinal: result.isFinal)
                }
            }
            
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    if !self.isGeneratingResponse && !self.synthesizer.isSpeaking {
                        self.stopListening()
                        self.startListening()
                    }
                }
            }
        }
        
        isListening = true
    }
    
    private func stopListening() {
        if audioEngine.isRunning { audioEngine.stop() }
        
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
    }
    
    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        guard isFinal else { return }
        
        let utterance = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        
        if let prompt = promptAfterWakeWord(in: utterance) {
            handleUserPrompt(prompt)
        }
    }
    
    private func promptAfterWakeWord(in text: String) -> String? {
        guard let range = text.range(of: wakeWord, options: [.caseInsensitive]) else {
            return nil
        }
        
        let remainder = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        
        return String(remainder)
    }
    
    private func handleUserPrompt(_ prompt: String) {
        guard !prompt.isEmpty else { return }
        guard !isGeneratingResponse else { return }
        
        stopListening()
        isGeneratingResponse = true
        
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            guard let self else { return }
            let answer = await self.generateResponse(for: prompt)
            
            await MainActor.run {
                self.isGeneratingResponse = false
                self.speak(answer)
            }
        }
    }
    
    private func generateResponse(for prompt: String) async -> String {
        guard #available(iOS 26.0, *),
              let session = languageModelSession else {
            return "Apple Foundation Models unavailable on this device."
        }
        
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Something went wrong."
        }
    }
    
    private func speak(_ text: String) {
        guard !text.isEmpty else {
            startListening()
            return
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }
}

extension ChatViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        startListening()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        startListening()
    }
}
