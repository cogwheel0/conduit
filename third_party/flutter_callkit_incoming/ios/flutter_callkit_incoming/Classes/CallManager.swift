//
//  CallManager.swift
//  flutter_callkit_incoming
//
//  Created by Hien Nguyen on 07/10/2021.
//

import Foundation
import CallKit

@available(iOS 10.0, *)
class CallManager: NSObject {
    
    private let callController = CXCallController()
    private var sharedProvider: CXProvider? = nil
    private(set) var calls = [Call]()
    
    
    func setSharedProvider(_ sharedProvider: CXProvider) {
        self.sharedProvider = sharedProvider
    }
    
    func startCall(_ data: Data) {
        let handle = CXHandle(type: self.getHandleType(data.handleType), value: data.getEncryptHandle())
        // Guard against malformed UUID strings — caller layers (Dart, native) sometimes pass
        // app-internal call identifiers that aren't UUID(8-4-4-4-12) shaped. Force-unwrapping
        // here would crash the host process (was the chronic SnowChat "iPhone caller endCall →
        // process dies" symptom before the Dart-side guard was added). Returning silently is
        // safe: no CallKit call gets registered, and the caller can detect the no-op via
        // its own state machine.
        guard let uuid = UUID(uuidString: data.uuid) else {
            NSLog("[CallkitIncoming] startCall: invalid UUID '\(data.uuid)' — ignored")
            return
        }
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = data.type > 0
        let callTransaction = CXTransaction()
        callTransaction.addAction(startCallAction)
        //requestCall
        self.requestCall(callTransaction, action: "startCall", completion: { _ in
            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = handle
            callUpdate.supportsDTMF = data.supportsDTMF
            callUpdate.supportsHolding = data.supportsHolding
            callUpdate.supportsGrouping = data.supportsGrouping
            callUpdate.supportsUngrouping = data.supportsUngrouping
            callUpdate.hasVideo = data.type > 0 ? true : false
            callUpdate.localizedCallerName = data.nameCaller
            self.sharedProvider?.reportCall(with: uuid, updated: callUpdate)
        })
    }
    
    func muteCall(call: Call, isMuted: Bool) {
        let muteAction = CXSetMutedCallAction(call: call.uuid, muted: isMuted)
        let callTransaction = CXTransaction()
        callTransaction.addAction(muteAction)
        self.requestCall(callTransaction, action: "muteCall")
    }
    
    func holdCall(call: Call, onHold: Bool) {
        let muteAction = CXSetHeldCallAction(call: call.uuid, onHold: onHold)
        let callTransaction = CXTransaction()
        callTransaction.addAction(muteAction)
        self.requestCall(callTransaction, action: "holdCall")
    }
    
    func endCall(call: Call) {
        let endCallAction = CXEndCallAction(call: call.uuid)
        let callTransaction = CXTransaction()
        callTransaction.addAction(endCallAction)
        //requestCall
        self.requestCall(callTransaction, action: "endCall")
    }
    
    func connectedCall(call: Call) {
        let callItem = self.callWithUUID(uuid: call.uuid)

        // Never re-answer an already-connected call. The CXAnswerCallAction
        // requested below makes the plugin re-emit ACTION_CALL_ACCEPT to the
        // app; if the app's accept handler calls setCallConnected again, that
        // becomes an accept -> connect -> answer -> accept loop that freezes
        // the call UI. Requesting another answer action for a connected call
        // is never useful.
        if callItem?.hasConnected == true {
            print("connectedCall ignored: call already connected \(call.uuid.uuidString)")
            return
        }
        callItem?.connectedCall(completion: nil)

        let answerAction = CXAnswerCallAction(call: call.uuid)
        let transaction = CXTransaction(action: answerAction)

        callController.request(transaction) { error in
            if let error = error {
                print("Error answering call: \(error.localizedDescription)")
            } else {
                // Call successfully answered
            }
        }
    }
    
    func endCallAlls() {
        let calls = callController.callObserver.calls
        for call in calls {
            let endCallAction = CXEndCallAction(call: call.uuid)
            let callTransaction = CXTransaction()
            callTransaction.addAction(endCallAction)
            self.requestCall(callTransaction, action: "endCallAlls")
        }
    }
    
    func activeCalls() -> [[String: Any]] {
        let calls = callController.callObserver.calls
        var json = [[String: Any]]()
        for call in calls {
            let callItem = self.callWithUUID(uuid: call.uuid)
            if(callItem != nil){
                var item: [String: Any] = callItem!.data.toJSON()
                item["accepted"] = callItem?.hasConnected
                json.append(item)
            }else {
                let item: [String: String] = ["id": call.uuid.uuidString]
                json.append(item)
            }
        }
        return json
    }
    
    
    func setHold(call: Call, onHold: Bool) {
        let handleCall = CXSetHeldCallAction(call: call.uuid, onHold: onHold)
        let callTransaction = CXTransaction()
        callTransaction.addAction(handleCall)
        //requestCall
    }
    
    
    private func requestCall(_ transaction: CXTransaction, action: String, completion: ((Bool) -> Void)? = nil) {
        callController.request(transaction){ error in
            if let error = error {
                //fail
                print("Error requesting transaction: \(error)")
            }else {
                if(action == "startCall"){
                    //TODO: push notification for Start Call
                }else if(action == "endCall" || action == "endCallAlls"){
                    //TODO: push notification for End Call
                }
                completion?(error == nil)
                print("Requested transaction successfully: \(action)")
            }
        }
    }
    
    
    private func getHandleType(_ handleType: String?) -> CXHandle.HandleType {
        var typeDefault = CXHandle.HandleType.generic
        switch handleType {
        case "number":
            typeDefault = CXHandle.HandleType.phoneNumber
            break
        case "email":
            typeDefault = CXHandle.HandleType.emailAddress
        default:
            typeDefault = CXHandle.HandleType.generic
        }
        return typeDefault
    }
    
    
    static let callsChangedNotification = Notification.Name("CallsChangedNotification")
    var callsChangedHandler: (() -> Void)?
    
    func callWithUUID(uuid: UUID) -> Call?{
        guard let idx = calls.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        return calls[idx]
    }
    
    func addCall(_ call: Call){
        calls.append(call)
        call.stateDidChange = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.callsChangedHandler?()
            strongSelf.postCallNotification()
        }
        callsChangedHandler?()
        postCallNotification()
    }
    
    func removeCall(_ call: Call){
        guard let idx = calls.firstIndex(where: { $0 === call }) else { return }
        calls.remove(at: idx)
        callsChangedHandler?()
        postCallNotification()
    }
    
    func removeAllCalls() {
        calls.removeAll()
        callsChangedHandler?()
        postCallNotification()
    }
    
    private func postCallNotification(){
        NotificationCenter.default.post(name: type(of: self).callsChangedNotification, object: self)
    }
    
    
}
