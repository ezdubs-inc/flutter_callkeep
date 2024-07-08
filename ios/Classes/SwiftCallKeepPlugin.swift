import AVFoundation
import CallKit
import Flutter
import UIKit

@available(iOS 10.0, *)
public class SwiftCallKeepPlugin: NSObject, FlutterPlugin, CXProviderDelegate {
    static let ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP = "co.doneservices.callkeep.DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP"

    static let ACTION_CALL_INCOMING = "co.doneservices.callkeep.ACTION_CALL_INCOMING"
    static let ACTION_CALL_START = "co.doneservices.callkeep.ACTION_CALL_START"
    static let ACTION_CALL_ACCEPT = "co.doneservices.callkeep.ACTION_CALL_ACCEPT"
    static let ACTION_CALL_DECLINE = "co.doneservices.callkeep.ACTION_CALL_DECLINE"
    static let ACTION_CALL_ENDED = "co.doneservices.callkeep.ACTION_CALL_ENDED"
    static let ACTION_CALL_TIMEOUT = "co.doneservices.callkeep.ACTION_CALL_TIMEOUT"

    static let ACTION_CALL_TOGGLE_HOLD = "co.doneservices.callkeep.ACTION_CALL_TOGGLE_HOLD"
    static let ACTION_CALL_TOGGLE_MUTE = "co.doneservices.callkeep.ACTION_CALL_TOGGLE_MUTE"
    static let ACTION_CALL_TOGGLE_DMTF = "co.doneservices.callkeep.ACTION_CALL_TOGGLE_DMTF"
    static let ACTION_CALL_TOGGLE_GROUP = "co.doneservices.callkeep.ACTION_CALL_TOGGLE_GROUP"
    static let ACTION_CALL_TOGGLE_AUDIO_SESSION = "co.doneservices.callkeep.ACTION_CALL_TOGGLE_AUDIO_SESSION"

    @objc public static var sharedInstance: SwiftCallKeepPlugin? = nil

    private var channel: FlutterMethodChannel? = nil
    private var eventChannel: FlutterEventChannel? = nil
    private var callManager: CallManager? = nil

    private var eventCallbackHandler: EventCallbackHandler?
    private var sharedProvider: CXProvider? = nil

    private var outgoingCall: Call?
    private var answerCall: Call?

    private var data: Data?
    private var isFromPushKit: Bool = false
    private let devicePushTokenVoIP = "DevicePushTokenVoIP"

    private func sendEvent(_ event: String, _ body: [String: Any?]?) {
        let data = body ?? [:] as [String: Any?]
        eventCallbackHandler?.send(event, data)
    }

    @objc public func sendEventCustom(_ event: String, body: Any?) {
        eventCallbackHandler?.send(event, body ?? [:] as [String: Any?])
    }

    public static func sharePluginWithRegister(with registrar: FlutterPluginRegistrar) -> SwiftCallKeepPlugin {
        if sharedInstance == nil {
            sharedInstance = SwiftCallKeepPlugin()
        }
        sharedInstance!.channel = FlutterMethodChannel(name: "flutter_callkeep", binaryMessenger: registrar.messenger())
        sharedInstance!.eventChannel = FlutterEventChannel(name: "flutter_callkeep_events", binaryMessenger: registrar.messenger())
        sharedInstance!.callManager = CallManager()
        sharedInstance!.eventCallbackHandler = EventCallbackHandler()
        sharedInstance!.eventChannel?.setStreamHandler(sharedInstance!.eventCallbackHandler as? FlutterStreamHandler & NSObjectProtocol)
        return sharedInstance!
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = sharePluginWithRegister(with: registrar)
        registrar.addMethodCallDelegate(instance, channel: instance.channel!)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "displayIncomingCall":
            guard let args = call.arguments else {
                result(FlutterError.nilArgument)
                return
            }
            if let getArgs = args as? [String: Any] {
                data = Data(args: getArgs)
                displayIncomingCall(data!, fromPushKit: false, completion: {})
            }
            result("OK")
        case "showMissCallNotification":
            result("OK")
        case "startCall":
            guard let args = call.arguments else {
                result(FlutterError.nilArgument)
                return
            }
            if let getArgs = args as? [String: Any] {
                data = Data(args: getArgs)
                configureAudioSession()
                startCall(data!, fromPushKit: false)
            }
            result("OK")
        case "endCall":
            guard let args = call.arguments else {
                result(FlutterError.nilArgument)
                return
            }
            if let getArgs = args as? [String: Any] {
                data = Data(args: getArgs)
                endCall(data!)
            }
            result("OK")
        case "connectCall":
            guard let args = call.arguments
            else {
                result(FlutterError.nilArgument)
                return
            }

            if let getArgs = args as? [String: Any] {
                data = Data(args: getArgs)
                connectCall(data!)
            }

            result("OK")
        case "activeCalls":
            result(callManager?.activeCalls())
        case "endAllCalls":
            callManager?.endAllCalls()
            result("OK")
        case "getDevicePushTokenVoIP":
            result(getDevicePushTokenVoIP())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    @objc public func setDevicePushTokenVoIP(_ deviceToken: String) {
        UserDefaults.standard.set(deviceToken, forKey: devicePushTokenVoIP)
        sendEvent(SwiftCallKeepPlugin.ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP, ["deviceTokenVoIP": deviceToken])
    }

    @objc public func getDevicePushTokenVoIP() -> String {
        return UserDefaults.standard.string(forKey: devicePushTokenVoIP) ?? ""
    }

    @objc public func displayIncomingCall(_ data: Data, fromPushKit: Bool, completion: @escaping () -> Void) {
        isFromPushKit = fromPushKit
        if fromPushKit {
            self.data = data
        }

        var handle: CXHandle?
        handle = CXHandle(type: CXHandle.HandleType.phoneNumber, value: data.handle)

        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = handle
        callUpdate.supportsDTMF = true
        callUpdate.supportsHolding = false
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
        // callUpdate.localizedCallerName = data.callerName

        initCallkitProvider(data)

        let uuid = UUID(uuidString: data.uuid)

        // configureAudioSession()
        sharedProvider?.reportNewIncomingCall(with: uuid!, update: callUpdate) { error in
            if error == nil {
                self.configureAudioSession()
                let call = Call(uuid: uuid!, data: data)
                call.handle = data.handle
                self.callManager?.addCall(call)
                self.sendEvent(SwiftCallKeepPlugin.ACTION_CALL_INCOMING, data.toJSON())
                // self.endCallNotExist(data)
            }

            completion()
        }
    }

    @objc public func startCall(_ data: Data, fromPushKit: Bool) {
        isFromPushKit = fromPushKit
        if fromPushKit {
            self.data = data
        }
        initCallkitProvider(data)
        callManager?.startCall(data)
    }

    @objc public func endCall(_ data: Data) {
        if let uuid = UUID(uuidString: data.uuid) {
            var call: Call? = callManager?.callWithUUID(uuid: uuid)
            if call == nil { return }

            if isFromPushKit {
                isFromPushKit = false
                sendEvent(SwiftCallKeepPlugin.ACTION_CALL_ENDED, data.toJSON())
            }
            callManager?.endCall(call: call!)
        }
    }

    @objc public func connectCall(_ data: Data) {
        if let uuid = UUID(uuidString: data.uuid) {
            let call = callManager?.callWithUUID(uuid: uuid)

            if call == nil { return }
            callManager?.connectCall(call: call!)
        }
    }

    @objc public func activeCalls() -> [[String: Any]]? {
        return callManager?.activeCalls()
    }

    @objc public func endAllCalls() {
        isFromPushKit = false
        callManager?.endAllCalls()
    }

    public func saveEndCall(_ uuid: String, _ reason: Int) {
        var endReason: CXCallEndedReason?
        switch reason {
        case 1:
            endReason = CXCallEndedReason.failed
        case 2, 6:
            endReason = CXCallEndedReason.remoteEnded
        case 3:
            endReason = CXCallEndedReason.unanswered
        case 4:
            endReason = CXCallEndedReason.answeredElsewhere
        case 5:
            endReason = CXCallEndedReason.declinedElsewhere
        default:
            break
        }
        if endReason != nil {
            sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: endReason!)
        }
    }

    func endCallNotExist(_ data: Data) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(data.duration)) {
            let call = self.callManager?.callWithUUID(uuid: UUID(uuidString: data.uuid)!)
            if call != nil && self.answerCall == nil && self.outgoingCall == nil {
                self.callEndTimeout(data)
            }
        }
    }

    func callEndTimeout(_ data: Data) {
        saveEndCall(data.uuid, 3)
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TIMEOUT, data.toJSON())
    }

    func getHandleType(_ handleType: String?) -> CXHandle.HandleType {
        var typeDefault = CXHandle.HandleType.generic
        switch handleType {
        case "number":
            typeDefault = CXHandle.HandleType.phoneNumber
        case "email":
            typeDefault = CXHandle.HandleType.emailAddress
        default:
            typeDefault = CXHandle.HandleType.generic
        }
        return typeDefault
    }

    func initCallkitProvider(_ data: Data) {
        if sharedProvider == nil {
            sharedProvider = CXProvider(configuration: createConfiguration(data))
            sharedProvider?.setDelegate(self, queue: nil)
        }
        callManager?.setSharedProvider(sharedProvider!)
    }

    func createConfiguration(_ data: Data) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration(localizedName: data.appName)
        configuration.supportsVideo = data.supportsVideo
        configuration.maximumCallGroups = data.maximumCallGroups
        configuration.maximumCallsPerCallGroup = data.maximumCallsPerCallGroup

        configuration.supportedHandleTypes = [
            CXHandle.HandleType.generic,
            CXHandle.HandleType.emailAddress,
            CXHandle.HandleType.phoneNumber,
        ]
        if #available(iOS 11.0, *) {
            configuration.includesCallsInRecents = data.includesCallsInRecents
        }
        if !data.iconName.isEmpty {
            if let image = UIImage(named: data.iconName) {
                configuration.iconTemplateImageData = image.pngData()
            } else {
                print("Unable to load icon \(data.iconName).")
            }
        }
        if !data.ringtoneFileName.isEmpty || data.ringtoneFileName != "system_ringtone_default" {
            configuration.ringtoneSound = data.ringtoneFileName
        }
        return configuration
    }

    func senddefaultAudioInterruptionNofificationToStartAudioResource() {
        print("changing audio session")
        // var userInfo: [AnyHashable: Any] = [:]
        // let intrepEndeRaw = AVAudioSession.InterruptionType.ended.rawValue
        // userInfo[AVAudioSessionInterruptionTypeKey] = intrepEndeRaw
        // userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        // NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: self, userInfo: userInfo)
    }

    func configureAudioSession() {
        // let session = AVAudioSession.sharedInstance()
        // do {
        //     print("SESSION SET UP with mode - \(data?.audioSessionMode)")
        //     try session.setCategory(AVAudioSession.Category.playAndRecord, options: [AVAudioSession.CategoryOptions.allowBluetooth, AVAudioSession.CategoryOptions.mixWithOthers])
        //     try session.setMode(getAudioSessionMode(data?.audioSessionMode))
        //     try session.setActive(true)
        //     try session.setPreferredSampleRate(16000)
        //     try session.setPreferredIOBufferDuration(0.005)
        // } catch {
        //     print("SESSION ERROR - \(error)")
        //     print(error)
        // }
    }

    func getAudioSessionMode(_ audioSessionMode: String?) -> AVAudioSession.Mode {
        var mode = AVAudioSession.Mode.default
        switch audioSessionMode {
        case "gameChat":
            mode = AVAudioSession.Mode.gameChat
        case "measurement":
            mode = AVAudioSession.Mode.measurement
        case "moviePlayback":
            mode = AVAudioSession.Mode.moviePlayback
        case "spokenAudio":
            mode = AVAudioSession.Mode.spokenAudio
        case "videoChat":
            mode = AVAudioSession.Mode.videoChat
        case "videoRecording":
            mode = AVAudioSession.Mode.videoRecording
        case "voiceChat":
            mode = AVAudioSession.Mode.voiceChat
        case "voicePrompt":
            if #available(iOS 12.0, *) {
                mode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
        default:
            mode = AVAudioSession.Mode.default
        }
        return mode
    }

    public func providerDidReset(_: CXProvider) {
        if callManager == nil { return }
        for call in callManager!.calls {
            call.endCall()
        }
        callManager?.removeAllCalls()
    }

    public func provider(_: CXProvider, perform action: CXStartCallAction) {
        let call = Call(uuid: action.callUUID, data: data!, isOutGoing: true)
        call.handle = action.handle.value
        configureAudioSession()
        print("Provider transaction")

        call.hasStartedConnectDidChange = { [weak self] in
            // self?.sharedProvider?.reportOutgoingCall(with: call.uuid, startedConnectingAt: nil)
        }
        call.hasConnectDidChange = { [weak self] in
            // self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: nil)
        }
        outgoingCall = call
        callManager?.addCall(call)
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_START, call.data.toJSON())
        action.fulfill()
    }

    public func provider(_: CXProvider, perform action: CXAnswerCallAction) {
        print("CALL WAS ANSWERED")
        guard let call = callManager?.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200)) {
            self.configureAudioSession()
        }
        call.data.isAccepted = true
        answerCall = call
        callManager?.updateCall(call)
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_ACCEPT, call.data.toJSON())
        action.fulfill()
    }

    public func provider(_: CXProvider, perform action: CXEndCallAction) {
        guard let call = callManager?.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.endCall()
        callManager?.removeCall(call)
        if answerCall == nil && outgoingCall == nil {
            sendEvent(SwiftCallKeepPlugin.ACTION_CALL_DECLINE, call.data.toJSON())
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                action.fulfill()
            }
        } else {
            sendEvent(SwiftCallKeepPlugin.ACTION_CALL_ENDED, call.data.toJSON())
            action.fulfill()
        }
        // We clear the cached outgoing or answered call based on which call has ended
        if call === outgoingCall { outgoingCall = nil }
        if call === answerCall { answerCall = nil }
    }

    public func provider(_: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = callManager?.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isOnHold = action.isOnHold
        call.isMuted = action.isOnHold
        callManager?.setHold(call: call, onHold: action.isOnHold)
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_HOLD, ["id": action.callUUID.uuidString, "isOnHold": action.isOnHold])
        action.fulfill()
    }

    public func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
        guard let call = callManager?.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isMuted = action.isMuted
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_MUTE, ["id": action.callUUID.uuidString, "isMuted": action.isMuted])
        action.fulfill()
    }

    public func provider(_: CXProvider, perform action: CXSetGroupCallAction) {
        guard (callManager?.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_GROUP, ["id": action.callUUID.uuidString, "callUUIDToGroupWith": action.callUUIDToGroupWith?.uuidString])
        action.fulfill()
    }

    public func provider(_: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard (callManager?.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_DMTF, ["id": action.callUUID.uuidString, "digits": action.digits, "type": action.type])
        action.fulfill()
    }

    public func provider(_: CXProvider, timedOutPerforming _: CXAction) {
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TIMEOUT, data?.toJSON())
    }

    public func provider(_: CXProvider, didActivate audioSession: AVAudioSession) {
        if answerCall?.hasConnected ?? false {
            senddefaultAudioInterruptionNofificationToStartAudioResource()
            return
        }
        if outgoingCall?.hasConnected ?? false {
            senddefaultAudioInterruptionNofificationToStartAudioResource()
            return
        }
        outgoingCall?.startCall(withAudioSession: audioSession) { success in
            if success {
                self.callManager?.addCall(self.outgoingCall!)
            }
        }
        answerCall?.ansCall(withAudioSession: audioSession) { _ in }
        senddefaultAudioInterruptionNofificationToStartAudioResource()
        configureAudioSession()
        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, ["answerCall": answerCall?.data.toJSON(), "outgoingCall": outgoingCall?.data.toJSON(), "isActivate": true])
    }

    public func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
        if outgoingCall?.isOnHold ?? false || answerCall?.isOnHold ?? false {
            print("Call is on hold")
            return
        }

        sendEvent(SwiftCallKeepPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, ["isActivate": false])
    }
}

class EventCallbackHandler: FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    public func send(_ event: String, _ body: Any) {
        let data: [String: Any] = [
            "event": event,
            "body": body,
        ]
        eventSink?(data)
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

extension FlutterError {
    static let nilArgument = FlutterError(
        code: "argument.nil",
        message: "Expected arguments when invoking channel method, but it is nil.", details: nil
    )
}
