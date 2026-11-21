//
//  Call.swift
//  flutter_callkit_incoming
//
//  Created by Hien Nguyen on 07/10/2021.
//

import Foundation
import AVFoundation

public class Call: NSObject {
    
    public var uuid: UUID
    public var data: Data
    public var isOutGoing: Bool
    
    public var handle: String?
    
    var stateDidChange: (() -> Void)?
    var hasStartedConnectDidChange: (() -> Void)?
    var hasConnectDidChange: (() -> Void)?
    var hasEndedDidChange: (() -> Void)?
    
    var connectData: Date?{
        didSet{
            stateDidChange?()
            hasStartedConnectDidChange?()
        }
    }
    
    var connectedData: Date?{
        didSet{
            stateDidChange?()
            hasConnectDidChange?()
        }
    }
    
    var endDate: Date?{
        didSet{
            stateDidChange?()
            hasEndedDidChange?()
        }
    }
    
    var isOnHold = false{
        didSet{
            stateDidChange?()
        }
    }
    
    var isMuted = false{
        didSet{
            
        }
    }
    
    var hasStartedConnecting: Bool{
        get{
            return connectData != nil
        }
        set{
            connectData = newValue ? Date() : nil
        }
    }
    
    var hasConnected: Bool {
        get{
            return connectedData != nil
        }
        set{
            connectedData = newValue ? Date() : nil
        }
    }
    
    var hasEnded: Bool {
        get{
            return endDate != nil
        }
        set{
            endDate = newValue ? Date() : nil
        }
    }
    
    var duration: TimeInterval {
        guard let connectDate = connectedData else {
            return 0
        }
        return Date().timeIntervalSince(connectDate)
    }
    
    init(uuid: UUID, data: Data, isOutGoing: Bool = false){
        self.uuid = uuid
        self.data = data
        self.isOutGoing = isOutGoing
    }
    
    var startCallCompletion: ((Bool) -> Void)?
    
    func startCall(withAudioSession audioSession: AVAudioSession ,completion :((_ success : Bool)->Void)?){
        startCallCompletion = completion
        hasStartedConnecting = true
    }
    
    var answCallCompletion :((Bool) -> Void)?
    
    func ansCall(withAudioSession audioSession: AVAudioSession ,completion :((_ success : Bool)->Void)?){
        answCallCompletion = completion
        hasStartedConnecting = true
    }
    
    var connectedCallCompletion: ((Bool) -> Void)?
    
    func connectedCall(completion :((_ success : Bool)->Void)?){
        connectedCallCompletion = completion
        hasConnected = true
    }
    
    func endCall(){
        hasEnded = true
    }
    
    func startAudio() {
        
    }
    
    
}

@objc public class Data: NSObject {
    @objc public var uuid: String
    @objc public var nameCaller: String
    @objc public var appName: String
    @objc public var handle: String
    @objc public var avatar: String
    @objc public var type: Int
    @objc public var normalHandle: Int
    @objc public var duration: Int

    @objc public var isAccepted: Bool
    @objc public var extra: NSDictionary
    @objc public var headers: NSDictionary

    //iOS
    @objc public var iconName: String
    @objc public var handleType: String
    @objc public var supportsVideo: Bool
    @objc public var maximumCallGroups: Int
    @objc public var maximumCallsPerCallGroup: Int
    @objc public var supportsDTMF: Bool
    @objc public var supportsHolding: Bool
    @objc public var supportsGrouping: Bool
    @objc public var supportsUngrouping: Bool
    @objc public var includesCallsInRecents: Bool
    @objc public var ringtonePath: String
    @objc public var configureAudioSession: Bool
    @objc public var audioSessionMode: String
    @objc public var audioSessionActive: Bool
    @objc public var audioSessionPreferredSampleRate: Double
    @objc public var audioSessionPreferredIOBufferDuration: Double
    
    //missedCallNotification
    @objc public var isShowMissedCallNotification: Bool = true
    @objc public var missedNotificationSubtitle: String
    @objc public var missedNotificationCallbackText: String
    @objc public var isShowCallback: Bool = true

    //callingNotification
    @objc public var isShowCallingNotification: Bool = true
    @objc public var callingNotificationSubtitle: String
    @objc public var callingNotificationHangupText: String
    @objc public var isShowHangup: Bool = true
    
    
    @objc public init(id: String, nameCaller: String, handle: String, type: Int) {
        self.uuid = id
        self.nameCaller = nameCaller
        self.appName = "Callkit"
        self.avatar = ""
        self.handle = handle
        self.type = type
        self.normalHandle = 0
        self.duration = 30000
        self.isAccepted = false

        self.extra = [:]
        self.headers = [:]

        self.iconName = "CallKitLogo"
        self.handleType = ""
        self.supportsVideo = true
        self.maximumCallGroups = 2
        self.maximumCallsPerCallGroup = 1
        self.supportsDTMF = true
        self.supportsHolding = true
        self.supportsGrouping = true
        self.supportsUngrouping = true
        self.includesCallsInRecents = true
        self.ringtonePath = ""
        self.configureAudioSession = true
        self.audioSessionMode = ""
        self.audioSessionActive = true
        self.audioSessionPreferredSampleRate = 44100.0
        self.audioSessionPreferredIOBufferDuration = 0.005

        self.isShowMissedCallNotification = true
        self.missedNotificationSubtitle = "Missed Call"
        self.missedNotificationCallbackText = "Call back"
        self.isShowCallback = true

        self.isShowCallingNotification = true
        self.callingNotificationSubtitle = "Calling"
        self.callingNotificationHangupText = "Hang up"
        self.isShowHangup = true
    }
    
    @objc public convenience init(args: NSDictionary) {
        var argsConvert = [String: Any?]()
        for (key, value) in args {
            argsConvert[key as! String] = value
        }
        self.init(args: argsConvert)
    }
    
    public init(args: [String: Any?]) {
        self.uuid = args["id"] as? String ?? ""
        self.nameCaller = args["nameCaller"] as? String ?? ""
        self.appName = args["appName"] as? String ?? "Callkit"
        self.handle = args["handle"] as? String ?? ""
        self.avatar = args["avatar"] as? String ?? ""
        self.type = args["type"] as? Int ?? 0
        self.duration = args["duration"] as? Int ?? 30000
        self.isAccepted = args["isAccepted"] as? Bool ?? false
        self.extra = args["extra"] as? NSDictionary ?? [:]
        self.headers = args["headers"] as? NSDictionary ?? [:]


        if let ios = args["ios"] as? [String: Any] {
            self.iconName = ios["iconName"] as? String ?? "CallKitLogo"
            self.handleType = ios["handleType"] as? String ?? ""
            self.normalHandle = ios["normalHandle"] as? Int ?? 0
            self.supportsVideo = ios["supportsVideo"] as? Bool ?? true
            self.maximumCallGroups = ios["maximumCallGroups"] as? Int ?? 2
            self.maximumCallsPerCallGroup = ios["maximumCallsPerCallGroup"] as? Int ?? 1
            self.supportsDTMF = ios["supportsDTMF"] as? Bool ?? true
            self.supportsHolding = ios["supportsHolding"] as? Bool ?? true
            self.supportsGrouping = ios["supportsGrouping"] as? Bool ?? true
            self.supportsUngrouping = ios["supportsUngrouping"] as? Bool ?? true
            self.includesCallsInRecents = ios["includesCallsInRecents"] as? Bool ?? true
            self.ringtonePath = ios["ringtonePath"] as? String ?? ""
            self.configureAudioSession = ios["configureAudioSession"] as? Bool ?? true
            self.audioSessionMode = ios["audioSessionMode"] as? String ?? ""
            self.audioSessionActive = ios["audioSessionActive"] as? Bool ?? true
            self.audioSessionPreferredSampleRate = ios["audioSessionPreferredSampleRate"] as? Double ?? 44100.0
            self.audioSessionPreferredIOBufferDuration = ios["audioSessionPreferredIOBufferDuration"] as? Double ?? 0.005
        }else {
            self.iconName = args["iconName"] as? String ?? "CallKitLogo"
            self.handleType = args["handleType"] as? String ?? ""
            self.normalHandle = args["normalHandle"] as? Int ?? 0
            self.supportsVideo = args["supportsVideo"] as? Bool ?? true
            self.maximumCallGroups = args["maximumCallGroups"] as? Int ?? 2
            self.maximumCallsPerCallGroup =  args["maximumCallsPerCallGroup"] as? Int ?? 1
            self.supportsDTMF = args["supportsDTMF"] as? Bool ?? true
            self.supportsHolding = args["supportsHolding"] as? Bool ?? true
            self.supportsGrouping = args["supportsGrouping"] as? Bool ?? true
            self.supportsUngrouping = args["supportsUngrouping"] as? Bool ?? true
            self.includesCallsInRecents = args["includesCallsInRecents"] as? Bool ?? true
            self.ringtonePath = args["ringtonePath"] as? String ?? ""
            self.configureAudioSession = args["configureAudioSession"] as? Bool ?? true
            self.audioSessionMode = args["audioSessionMode"] as? String ?? ""
            self.audioSessionActive = args["audioSessionActive"] as? Bool ?? true
            self.audioSessionPreferredSampleRate = args["audioSessionPreferredSampleRate"] as? Double ?? 44100.0
            self.audioSessionPreferredIOBufferDuration = args["audioSessionPreferredIOBufferDuration"] as? Double ?? 0.005
        }
        if let missedCallNotification = args["missedCallNotification"] as? [String: Any] {
            self.isShowMissedCallNotification = missedCallNotification["showNotification"] as? Bool ?? true
            self.missedNotificationSubtitle = missedCallNotification["subtitle"] as? String ?? "Missed Call"
            self.missedNotificationCallbackText = missedCallNotification["callbackText"] as? String ?? "Call back"
            self.isShowCallback = missedCallNotification["isShowCallback"] as? Bool ?? true
        }else {
            self.isShowMissedCallNotification = true
            self.missedNotificationSubtitle = "Missed Call"
            self.missedNotificationCallbackText = "Call back"
            self.isShowCallback = true
        }

        if let callingNotification = args["callingNotification"] as? [String: Any] {
            self.isShowCallingNotification = callingNotification["showNotification"] as? Bool ?? true
            self.callingNotificationSubtitle = callingNotification["subtitle"] as? String ?? "Calling"
            self.callingNotificationHangupText = callingNotification["callbackText"] as? String ?? "Hang up"
            self.isShowHangup = callingNotification["isShowCallback"] as? Bool ?? true
        }else {
            self.isShowCallingNotification = true
            self.callingNotificationSubtitle = "Calling"
            self.callingNotificationHangupText = "Hang up"
            self.isShowHangup = true
        }
    }
    
    open func toJSON() -> [String: Any] {
        let missedCallNotification: [String : Any] = [
            "showNotification": isShowMissedCallNotification,
            "subtitle": missedNotificationSubtitle,
            "callbackText": missedNotificationCallbackText,
            "isShowCallback": isShowCallback
        ]
        let callingNotification: [String : Any] = [
            "showNotification": isShowCallingNotification,
            "subtitle": callingNotificationSubtitle,
            "callbackText": callingNotificationHangupText,
            "isShowCallback": isShowHangup
        ]
        let ios: [String : Any] = [
            "iconName": iconName,
            "handleType": handleType,
            "normalHandle": normalHandle,
            "supportsVideo": supportsVideo,
            "maximumCallGroups": maximumCallGroups,
            "maximumCallsPerCallGroup": maximumCallsPerCallGroup,
            "supportsDTMF": supportsDTMF,
            "supportsHolding": supportsHolding,
            "supportsGrouping": supportsGrouping,
            "supportsUngrouping": supportsUngrouping,
            "includesCallsInRecents": includesCallsInRecents,
            "ringtonePath": ringtonePath,
            "configureAudioSession": configureAudioSession,
            "audioSessionMode": audioSessionMode,
            "audioSessionActive": audioSessionActive,
            "audioSessionPreferredSampleRate": audioSessionPreferredSampleRate,
            "audioSessionPreferredIOBufferDuration": audioSessionPreferredIOBufferDuration
        ]
        let map: [String : Any] = [
            "uuid": uuid,
            "id": uuid,
            "nameCaller": nameCaller,
            "appName": appName,
            "handle": handle,
            "avatar": avatar,
            "type": type,
            "duration": duration,
            "isAccepted": isAccepted,
            "extra": extra,
            "headers": headers,
            "ios": ios,
            "missedCallNotification": missedCallNotification,
            "callingNotification": callingNotification
        ]
        return map
    }
    
    func getEncryptHandle() -> String {
        if (normalHandle > 0) {
            return handle
        }
        do {
            var map: [String: Any] = [:]

            map["nameCaller"] = nameCaller
            map["handle"] = handle
            
            var mapExtras = extra as? [String: Any]
            
            if (mapExtras == nil) {
                print("error casting dictionary to [String: Any]")
                return String(format: "{\"nameCaller\":\"%@\", \"handle\":\"%@\"}", nameCaller, handle).encryptHandle()
            }
            
            for (key, value) in mapExtras! {
                map[key] = value
            }
            
            let mapData = try JSONSerialization.data(withJSONObject: map, options: .prettyPrinted)

            let mapString: String = String(data: mapData, encoding: .utf8) ?? ""

            return mapString.encryptHandle()
        } catch {
            print("error encrypting call data")
            return String(format: "{\"nameCaller\":\"%@\", \"handle\":\"%@\"}", nameCaller, handle).encryptHandle()
        }
       
    }
    
    
}
