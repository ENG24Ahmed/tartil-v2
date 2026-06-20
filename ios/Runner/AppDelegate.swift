import AVFoundation
import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, SFSpeechRecognizerDelegate {
  private let methodChannelName = "quran_app/native_speech"
  private let eventChannelName = "quran_app/native_speech/events"

  private var eventSink: FlutterEventSink?
  private let audioEngine = AVAudioEngine()
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var manualStopRequested = false
  private var continuousMode = false
  private var currentPartialResults = true
  private var listeningStatusSent = false
  private var tapInstalled = false
  private let requestSwapQueue = DispatchQueue(label: "quran.recognition.swap")
  private var lastRestartAt: Date = .distantPast
  private var consecutiveRestartCount = 0
  private var pendingRestartWorkItem: DispatchWorkItem?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let methodChannel = FlutterMethodChannel(
        name: methodChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      let eventChannel = FlutterEventChannel(
        name: eventChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      eventChannel.setStreamHandler(self)
      methodChannel.setMethodCallHandler(handleMethodCall)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(makeSpeechRecognizer(locale: "ar")?.isAvailable ?? false)
    case "hasPermission":
      result(hasSpeechPermission() && hasMicrophonePermission())
    case "requestPermission":
      requestPermissions(result: result)
    case "startListening":
      startListening(call: call, result: result)
    case "stopListening":
      manualStopRequested = true
      continuousMode = false
      stopListeningInternal(notifyStatus: true, cancelTask: false)
      result(nil)
    case "cancelListening":
      manualStopRequested = true
      continuousMode = false
      stopListeningInternal(notifyStatus: true, cancelTask: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermissions(result: @escaping FlutterResult) {
    let group = DispatchGroup()
    var speechGranted = hasSpeechPermission()
    var micGranted = hasMicrophonePermission()

    if !speechGranted {
      group.enter()
      SFSpeechRecognizer.requestAuthorization { status in
        speechGranted = status == .authorized
        group.leave()
      }
    }

    if !micGranted {
      group.enter()
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        micGranted = granted
        group.leave()
      }
    }

    group.notify(queue: .main) {
      result(speechGranted && micGranted)
    }
  }

  private func startListening(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard hasSpeechPermission(), hasMicrophonePermission() else {
      result(
        FlutterError(
          code: "missing_permission",
          message: "Speech and microphone permissions are required.",
          details: nil
        ))
      return
    }

    let args = call.arguments as? [String: Any]
    let locale = (args?["locale"] as? String) ?? "ar"
    let partialResults = (args?["partialResults"] as? Bool) ?? true
    let continuous = (args?["continuous"] as? Bool) ?? false

    guard let recognizer = makeSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      result(
        FlutterError(
          code: "not_available",
          message: "Speech recognition is unavailable on this device.",
          details: nil
        ))
      return
    }

    stopListeningInternal(notifyStatus: false, cancelTask: true)
    speechRecognizer = recognizer
    speechRecognizer?.delegate = self
    currentPartialResults = partialResults
    continuousMode = continuous
    manualStopRequested = false
    listeningStatusSent = false
    consecutiveRestartCount = 0
    lastRestartAt = .distantPast

    do {
      try configureAudioSession()
      try startAudioEngineIfNeeded()
      startRecognitionTask()
      if !listeningStatusSent {
        listeningStatusSent = true
        sendStatus("listening")
      }
      result(nil)
    } catch {
      stopListeningInternal(notifyStatus: false, cancelTask: true)
      result(
        FlutterError(
          code: "start_failed",
          message: error.localizedDescription,
          details: nil
        ))
    }
  }

  private func configureAudioSession() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private func startAudioEngineIfNeeded() throws {
    if audioEngine.isRunning {
      return
    }

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    if tapInstalled {
      inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
      [weak self] buffer, _ in
      // Read the current request atomically to avoid losing buffers during a swap.
      let request: SFSpeechAudioBufferRecognitionRequest? = self?.requestSwapQueue.sync {
        return self?.recognitionRequest
      }
      request?.append(buffer)
    }
    tapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()
  }

  private func startRecognitionTask() {
    guard let recognizer = speechRecognizer else { return }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = currentPartialResults

    // Swap atomically so the audio tap never sees a nil request.
    let oldRequest = requestSwapQueue.sync { () -> SFSpeechAudioBufferRecognitionRequest? in
      let prev = self.recognitionRequest
      self.recognitionRequest = request
      return prev
    }
    oldRequest?.endAudio()
    if let oldTask = recognitionTask {
      // Prevent task accumulation in long sessions: keep only one active task.
      oldTask.cancel()
    }

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] recognitionResult, error in
      guard let self else { return }

      if let recognitionResult {
        self.sendRecognitionResult(recognitionResult)
        if recognitionResult.isFinal {
          self.consecutiveRestartCount = 0
          if self.continuousMode && !self.manualStopRequested {
            self.restartRecognitionTask()
          } else if !self.continuousMode {
            self.stopListeningInternal(notifyStatus: false, cancelTask: false)
          }
          return
        }
      }

      if let error {
        if self.manualStopRequested {
          // Stop has already been issued; nothing to do here.
          return
        }

        if self.continuousMode {
          // Silent rotation — never surface intermittent errors during continuous mode.
          self.consecutiveRestartCount += 1
          let adaptive = min(0.35, 0.05 + (Double(self.consecutiveRestartCount) * 0.03))
          self.restartRecognitionTask(after: adaptive)
        } else {
          self.sendEvent([
            "type": "error",
            "code": "recognition_error",
            "message": error.localizedDescription,
          ])
          self.stopListeningInternal(notifyStatus: false, cancelTask: false)
        }
      }
    }
  }

  private func restartRecognitionTask(after delay: TimeInterval = 0.0) {
    guard continuousMode, !manualStopRequested else { return }
    pendingRestartWorkItem?.cancel()
    pendingRestartWorkItem = nil

    let scheduleDelay: TimeInterval
    let elapsed = Date().timeIntervalSince(lastRestartAt)
    if elapsed < 0.12 {
      // Avoid restart thrashing on dense callback bursts.
      scheduleDelay = max(delay, 0.12 - elapsed)
    } else {
      scheduleDelay = delay
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingRestartWorkItem = nil
      self.lastRestartAt = Date()
      if scheduleDelay <= 0 {
        guard self.continuousMode, !self.manualStopRequested else { return }
        self.startRecognitionTask()
      } else {
        guard self.continuousMode, !self.manualStopRequested else { return }
        self.startRecognitionTask()
      }
    }
    pendingRestartWorkItem = work
    if scheduleDelay <= 0 {
      DispatchQueue.main.async(execute: work)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + scheduleDelay, execute: work)
    }
  }

  private func stopListeningInternal(notifyStatus: Bool, cancelTask: Bool) {
    consecutiveRestartCount = 0
    lastRestartAt = .distantPast
    pendingRestartWorkItem?.cancel()
    pendingRestartWorkItem = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }

    let oldRequest = requestSwapQueue.sync { () -> SFSpeechAudioBufferRecognitionRequest? in
      let prev = self.recognitionRequest
      self.recognitionRequest = nil
      return prev
    }
    oldRequest?.endAudio()

    if cancelTask {
      recognitionTask?.cancel()
    }
    recognitionTask = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

    if notifyStatus {
      sendStatus("stopped")
    }
  }

  private func makeSpeechRecognizer(locale: String) -> SFSpeechRecognizer? {
    // Try the requested locale first, then fall back through common Arabic variants.
    // SFSpeechRecognizer may be nil or unavailable for "ar" alone on devices whose
    // system language is not Arabic; "ar-SA" is Apple's officially listed locale.
    var seen = Set<String>()
    for id in [locale, "ar-SA", "ar-AE", "ar-EG", "ar-IQ", "ar"] {
      guard seen.insert(id).inserted else { continue }
      if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
        recognizer.isAvailable
      {
        return recognizer
      }
    }
    return nil
  }

  private func hasSpeechPermission() -> Bool {
    return SFSpeechRecognizer.authorizationStatus() == .authorized
  }

  private func hasMicrophonePermission() -> Bool {
    return AVAudioSession.sharedInstance().recordPermission == .granted
  }

  private func sendRecognitionResult(_ result: SFSpeechRecognitionResult) {
    let text = result.bestTranscription.formattedString.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !text.isEmpty else { return }

    let segments = result.bestTranscription.segments
    let confidence: Double? = segments.isEmpty
      ? nil
      : Double(segments.reduce(Float(0)) { $0 + $1.confidence }) / Double(segments.count)

    var payload: [String: Any] = [
      "type": "result",
      "text": text,
      "isFinal": result.isFinal,
    ]
    if let confidence {
      payload["confidence"] = confidence
    }
    sendEvent(payload)
  }

  private func sendStatus(_ status: String) {
    sendEvent([
      "type": "status",
      "status": status,
    ])
  }

  private func sendEvent(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }

  func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
    if !available {
      sendEvent([
        "type": "error",
        "code": "not_available",
        "message": "Speech recognizer became unavailable.",
      ])
    }
  }
}
