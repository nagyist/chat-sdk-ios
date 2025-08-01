//
//  ChatKitSetup.swift
//  ChatSDKSwift
//
//  Created by ben3 on 18/04/2021.
//  Copyright © 2021 deluge. All rights reserved.
//

import Foundation
import ChatSDK
import AVKit
import ZLImageEditor
import RxSwift

open class FileKeys {
    
    public static let data = "file-data"
    public static let mimeType = "file-mime-type"

}

public protocol MessageProvider {
    func new(for message: PMessage) -> CKMessage
}

public protocol OnCreateListener {
    func onCreate(for vc: ChatViewController, model: ChatModel, thread: PThread)
}

public protocol MessageOnClickListener {
    func onClick(for vc: ChatViewController?, message: AbstractMessage)
}

public protocol OptionProvider {
    func provide(for vc: ChatViewController, thread: PThread) -> Option
}

@objc open class ChatKitModule: NSObject, PModule {
    
    static let instance = ChatKitModule()
    @objc public static func shared() -> ChatKitModule {
        return instance
    }

    open var integration: ChatKitIntegration?
    
    open func get() -> ChatKitIntegration {
        if integration == nil {
            integration = ChatKitIntegration()
        }
        return integration!
    }

    @objc open func with(integration: ChatKitIntegration) -> ChatKitModule {
        self.integration = integration
        return self
    }
    
    open func activate() {
        
        if BChatSDK.fileMessage() != nil {
            // File Message
            let fileRegistration = MessageCellRegistration(messageType: String(bMessageTypeFile.rawValue), contentClass: FileMessageContent.self)
            get().add(messageRegistration: fileRegistration)

            get().add(newMessageProvider: FileMessageProvider(), type: Int(bMessageTypeFile.rawValue))
            get().add(optionProvider: FileOptionProvider())
            get().add(messageOnClickListener: FileMessageOnClick())
        }
        
        get().add(messageOnClickListener: Base64MessageOnClick())
        
        get().activate()
    }
    
    open func weight() -> Int32 {
        return 50
    }
}

open class  ChatKitIntegration: NSObject, ChatViewControllerDelegate, ChatModelDelegate, ChatViewControllerTypingDelegate, RecordViewDelegate {
    
    open var model: ChatModel?

    open weak var weakVC: ChatViewController?

    open var thread: PThread?
    open var locationAction: BSelectLocationAction?

    open var onCreateListeners = [OnCreateListener]()

    open var messageRegistrations = [MessageCellRegistration]()
    open var newMessageProviders = [Int: MessageProvider]()
    open var optionProviders = [OptionProvider]()
    open var messageOnClick = [MessageOnClickListener]()
    
    open var observers = BNotificationObserverList()

    public override init() {
        super.init()
    }
    
    open func add(optionProvider: OptionProvider) {
        optionProviders.append(optionProvider)
    }

    open func add(messageOnClickListener: MessageOnClickListener) {
        messageOnClick.append(messageOnClickListener)
    }

    open func add(messageRegistration: MessageCellRegistration) {
        messageRegistrations.append(messageRegistration)
    }

    open func add(newMessageProvider: MessageProvider, type: Int) {
        newMessageProviders[type] = newMessageProvider
    }

    open func add(onCreateListener: OnCreateListener) {
        onCreateListeners.append(onCreateListener)
    }
    
    open func addObservers() {

        // Add a listener to add outgoing messages to the download area so we don't have to download them again...
        observers.add(BChatSDK.hook().add(BHook({ [weak self] input in
            if let message = input?[bHook_PMessage] as? PMessage, let data = input?[bHook_NSData] as? Data {
                if let m = self?.model?.messagesModel.message(for: message.entityID()) as? UploadableMessage {
                        // Get the extension
                    m.uploadFinished(data, error: nil)
                    _ = self?.model?.messagesModel.updateMessage(id: message.entityID())
                }
            }
        }), withName: bHookMessageDidUpload))

        observers.add(BChatSDK.hook().add(BHook({ [weak self] input in
            if let user = input?[bHook_PUser] as? PUser {
                if self?.thread?.contains(user) ?? false {
                    self?.weakVC?.updateNavigationBar()
                }
            }
        }), withName: bHookUserLastOnlineUpdated))

        observers.add(BChatSDK.hook().add(BHook({ [weak self] input in
            if let thread = input?[bHook_PThread] as? PThread {
                if self?.thread?.entityID() == thread.entityID() {
                    self?.weakVC?.updateNavigationBar()
                }
            }
        }), withName: bHookThreadUpdated))

//        [_disposeOnDisappear add:[BChatSDK.hook addHook:[BHook hookOnMain:^(NSDictionary * dict) {
//            id<PThread> thread = dict[bHook_PThread];
//            if (thread) {
//                [weakSelf reloadDataForThread:thread];
//            }
//        }] withNames: @[bHookThreadUpdated]]];


        // Add a listener to add outgoing messages to the download area so we don't have to download them again...
        observers.add(BChatSDK.hook().add(BHook({ [weak self] input in
            self?.updateConnectionStatus()
        }), withNames: [bHookInternetConnectivityDidChange, bHookServerConnectionStatusUpdated]))
                
        observers.add(BChatSDK.hook().add(BHook(onMain:{ [weak self] input in
            if let message = input?[bHook_PMessage] as? PMessage {
                if let m = self?.model?.messagesModel.message(for: message.entityID()), let content = m.messageContent() as? UploadableContent {
                    content.uploadStarted?()
                }
            }
        }, weight: 50), withName: bHookMessageWillUpload))
        
        observers.add(BChatSDK.hook().add(BHook({ [weak self] input in
            if let message = input?[bHook_PMessage] as? PMessage, let progress = input?[bHook_ObjectValue] as? Progress {
                if let content = self?.model?.messagesModel.message(for: message.entityID())?.messageContent() as? UploadableContent {
                    //
                    let total = Float(progress.totalUnitCount)
                    let current = Float(progress.completedUnitCount)
                    
                    content.setUploadProgress?(current / total, total: total / 1000)
                }
            }
        }), withName: bHookMessageUploadProgress))
        
        observers.add(BChatSDK.hook().add(BHook({ [weak self] data in
            if let thread = data?[bHook_PThread] as? PThread, thread.isEqual(self?.thread) {
                if let text = data?[bHook_NSString] as? String {
                    self?.weakVC?.setSubtitle(text: text)
                } else {
                    self?.weakVC?.setSubtitle()
                }
            }
        }), withName: bHookTypingStateUpdated))

        observers.add(BChatSDK.hook().add(BHook({ [unowned self] data in
//            weakVC?.showError(message: t(Strings.messageSendFailed), completion: nil)
            
            if let messageId = data?[bHook_StringId] as? String {
                if let message = BChatSDK.db().fetchEntity(withID: messageId, withType: bMessageEntity) as? PMessage, let t = message.thread() {
                    if (t.isEqual(thread)) {
                        _ = model?.messagesModel.updateMessage(id: message.entityID(), animated: false).subscribe()
                    }
                    weakVC?.showResendDialog(callback: { result in
                        if result {
                            BChatSDK.thread().send(message)
                        }
                    })
                }
            }

        }), withName: bHookMessageDidFailToSend))
        
        observers.add(BChatSDK.hook().add(BHook({ [weak self] data in
            if let thread = self?.thread, let user = data?[bHook_PUser] as? PUser {
                if thread.contains(user) {
                    self?.weakVC?.setSubtitle()
                }
            }
        }), withName: bHookUserUpdated))
        
        observers.add(BChatSDK.hook().add(BHook({ [weak self] data in
            if  let thread = data?[bHook_PThread] as? PThread, thread.isEqual(to: self?.thread), let user = data?[bHook_PUser] as? PUser, user.isMe() {
                self?.updateViewForPermissions(user, thread: thread)
            }
        }), withName: bHookThreadUserRoleUpdated))
        
        // Add the observers
        observers.add(BChatSDK.hook().add(BHook({ [weak self] data in
            if let message = data?[bHook_PMessage] as? PMessage, let t = message.thread(), let user = message.userModel(), let thread = self?.thread {
                if (t.isEqual(thread)) {
                    if !user.isMe() {
                        self?.markRead(thread: thread)
                    } else {
                        message.setDelivered(true)
                    }
                    if let message = CKMessageStore.shared().message(with: message.entityID()) {
                        _ = self?.model?.messagesModel.updateMessage(id: message.messageId(), animated: false).subscribe()
                    } else {
                        _ = self?.model?.messagesModel.addMessage(toEnd: CKMessageStore.shared().message(for: message), animated: true, scrollToBottom: true).subscribe()
                    }
                }
            }
        }), withNames: [bHookMessageWillSend, bHookMessageRecieved, bHookMessageWillUpload]))
                
        observers.add(BChatSDK.hook().add(BHook(onMain: { [weak self] data in
            if let message = data?[bHook_PMessage] as? PMessage, let t = message.thread(), let thread = self?.thread {
                if t.isEqual(thread) {
                    _ = self?.model?.messagesModel.updateMessage(id: message.entityID(), animated: false).subscribe()
                }
            }
        }), withName: bHookMessageReadReceiptUpdated))

        observers.add(BChatSDK.hook().add(BHook(onMain: { [weak self] data in
            if let id = data?[bHook_StringId] as? String, let message = CKMessageStore.shared().message(with: id) {
                _ = self?.model?.messagesModel.removeMessage(message).subscribe(onCompleted: {
                    
                })
            }
        }), withName: bHookMessageWasDeleted))

//        observers.add(BChatSDK.hook().add(BHook(onMain: { [weak self] data in
//            if let message = data?[bHook_PMessage] as? PMessage {
////                _ = self?.model?.messagesModel.updateMessage(id: message.entityID())
////                _ = self?.model?.messagesModel.view?.reload(messages: [message], animated: false)
//            }
//        }), withName: bHookMessageUpdated))

        observers.add(BChatSDK.hook().add(BHook(onMain: { [weak self] data in
            if let threads = data?[bHook_PThreads] as? [PThread] {
                for t in threads {
                    if t.entityID() == self?.thread?.entityID() {
                        _ = self?.model?.messagesModel.removeAllMessages(animated: false).subscribe()
                    }
                }
            }
        }), withName: bHookAllMessagesDeleted))
    }

    open func activate() {
        BChatSDK.ui().setChatViewController({ [weak self] (thread: PThread?) -> UIViewController? in
            if let thread = thread {
                return self?.chatViewController(thread)
            }
            return nil
        })
    }
    
    open func chatViewController(_ thread: PThread) -> UIViewController? {
        let ckThread = CKThread(thread)

        let model = ChatModel(ckThread, delegate: self)
        self.model = model
        self.thread = thread
        
        // Connect up the download manager so we can update the cell when
        // the message download updates
        ChatKit.downloadManager().addListener(DefaultDownloadManagerListener(model.messagesModel))
        
        //
        // Cell registrations
        //
        
        // Map the message type to a content view type
        
        // Create the chat view controller
        let vc = ChatKit.provider().chatViewController(model)
        weakVC = vc
        
        addObservers()

        vc.delegate = self
        vc.typingDelegate = self
        
        registerMessageCells()
        
        // TODO: ??
        //addRightBarButtonItems()

        addSendBarActions()
        addToolbarActions()
        addKeyboardOverlays()
        addNavigationBarAction()
        
        weakVC?.setReadOnly(thread.isReadOnly())
        
        markRead(thread: thread)
        
        for listener in onCreateListeners {
            listener.onCreate(for: vc, model: model, thread: thread)
        }

        return vc
    }
    
    open func updateViewForPermissions(_ user: PUser, thread: PThread) {
        if thread.typeIs(bThreadFilterGroup) {
            updateRightBarButtonItem()
            let hasVoice = BChatSDK.thread().hasVoice(thread.entityID(), forUser: user.entityID())
            weakVC?.setReadOnly(!hasVoice)
        }
    }
    
    open func addRightBarButtonItems() {
         var buttons = [
            NavBarButton(UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil), action: { [weak self] item in
                if let thread = self?.thread {
                    let flvc = BChatSDK.ui().friendsViewControllerWithUsers(toExclude: Array(thread.users()), onComplete: { users, name, image in
                        BChatSDK.thread().addUsers(users, to: thread)
                    })
                    flvc?.setRightBarButtonActionTitle(Bundle.t(bAdd))
                    flvc?.hideGroupNameView = true
                    flvc?.maximumSelectedUsers = 0
                    
                    self?.weakVC?.present(UINavigationController(rootViewController: flvc!), animated: true, completion: nil)
                }
            })
        ]
        
        if let ch = BChatSDK.call(), let thread = thread, ch.callEnabled(thread: thread.entityID()) {
            buttons.append(NavBarButton(UIBarButtonItem(image: ChatKit.asset(icon: "icn_30_call"), style: .plain, target: nil, action: nil), action: { [weak self] item in
                ch.call(user: thread.otherUser().entityID(), viewController: self?.weakVC)
            }))
        }
                
        weakVC?.rightBarButtonItems = buttons

    }
    
    open func registerMessageCells() {
        var registrations = [
            MessageCellRegistration(messageType: String(bMessageTypeText.rawValue), contentClass: TextMessageContent.self),
            MessageCellRegistration(messageType: String(bMessageTypeImage.rawValue), contentClass: ImageMessageContent.self),

            MessageCellRegistration(messageType: String(bMessageTypeBase64Image.rawValue), contentClass: Base64ImageMessageContent.self),

            MessageCellRegistration(messageType: String(bMessageTypeLocation.rawValue), contentClass: ImageMessageContent.self),
            MessageCellRegistration(messageType: String(bMessageTypeSystem.rawValue), nibName: "SystemMessageCell", contentClass: SystemMessageContent.self)
        ]
        
        if BChatSDK.audioMessage() != nil {
            registrations.append(MessageCellRegistration(messageType: String(bMessageTypeAudio.rawValue), contentClass: AudioMessageContent.self))
        }
        if BChatSDK.videoMessage() != nil {
            registrations.append(MessageCellRegistration(messageType: String(bMessageTypeVideo.rawValue), contentClass: VideoMessageContent.self))
        }

        for reg in self.messageRegistrations {
            registrations.append(reg)
        }

        model?.messagesModel.registerMessageCells(registrations: registrations)
    }
    
    open func addNavigationBarAction() {
        weakVC?.headerView.onTap = { [weak self] in
            if let vc = self?.weakVC, let thread = self?.thread {
                vc.present(BChatSDK.ui().usersViewNavigationController(with: thread, parentNavigationController: vc.navigationController), animated: true, completion: nil)
            }
        }
    }
    
    open func addKeyboardOverlays() {
        let optionsOverlay = ChatKit.provider().optionsKeyboardOverlay()

        var options = getOptions()
        if let vc = weakVC, let thread = thread {
            for provider in optionProviders {
                options.append(provider.provide(for: vc, thread: thread))
            }
        }
        optionsOverlay.setOptions(options: options)
        model?.addKeyboardOverlay(name: OptionsKeyboardOverlay.key, overlay: optionsOverlay)

        if BChatSDK.audioMessage() != nil {
            let recordOverlay = ChatKit.provider().recordKeyboardOverlay(self)
//            let recordOverlay = RecordKeyboardOverlay.new(self)
            model?.addKeyboardOverlay(name: RecordKeyboardOverlay.key, overlay: recordOverlay)
        }
    }
    
    open func markRead(thread: PThread) {
        if  weakVC != nil {
            if let rr = BChatSDK.readReceipt() {
                rr.markRead(thread)
            } else {
                thread.markRead()
            }
        }
    }
        
    open func updateConnectionStatus() {
        let connectionStatus = BChatSDK.core().connectionStatus?() ?? bConnectionStatusConnected
        let status = ConnectionStatus.init(rawValue: Int(connectionStatus.rawValue))
        let connected = BChatSDK.connectivity()?.isConnected() ?? true

        weakVC?.updateConnectionStatus(status)

        weakVC?.navigationItem.rightBarButtonItem?.isEnabled = connected
        if connected && status == .connected {
            weakVC?.goOnline()
        } else {
            weakVC?.goOffline()
        }
    }
    
    open func updateRightBarButtonItem() {
        if let thread = thread {
            weakVC?.navigationItem.rightBarButtonItem?.isEnabled = BChatSDK.thread().canAddUsers(thread.entityID())
        } else {
            weakVC?.navigationItem.rightBarButtonItem?.isEnabled = false
        }
    }
    
    // ChatViewControllerDelegate
    
    open func viewDidLoad() {
        updateRightBarButtonItem()
        updateConnectionStatus()
    }
    
    open func viewWillAppear() {
        BChatSDK.ui().setLocalNotificationHandler({ [weak self] thread in
            if let thread = thread {
                var enable = BLocalNotificationHandler().showLocalNotification(thread)
                if enable, let current = self?.thread, thread.entityID() != current.entityID() {
                    return true
                }
            }
            return false
        })
        if let thread = thread {
            updateViewForPermissions(BChatSDK.currentUser(), thread: thread)
        }
    }
    
    open func viewDidAppear() {
        if let thread = thread {
            if thread.typeIs(bThreadFilterPublic) {
                BChatSDK.thread().addUsers([BChatSDK.currentUser()], to: thread)
            }
        }
    }

    open func viewWillDisappear() {
        
    }
    
    open func viewDidDisappear() {
        if let thread = thread {
            if thread.typeIs(bThreadFilterPublic) && (!BChatSDK.config().publicChatAutoSubscriptionEnabled || thread.meta()[bMute] != nil) {
                BChatSDK.thread().removeUsers([BChatSDK.currentUserID()], fromThread: thread.entityID())
            }
        }
    }
    
    open func viewDidDestroy() {
        ChatKit.downloadManager().removeAllListeners()
        observers.dispose()
        print("Destroy")
    }
    
    // ChatModel Delegate
    
    open func loadMessages(with oldestMessage: AbstractMessage?) -> Single<[AbstractMessage]> {
        return Single<[AbstractMessage]>.create { [weak self] single in
            if let model = self?.model?.messagesModel, let thread = BChatSDK.db().fetchEntity(withID: model.conversation.conversationId(), withType: bThreadEntity) as? PThread {
                _ = BChatSDK.thread().loadMoreMessages(from: oldestMessage?.messageDate(), for: thread).thenOnMain({ success in
                    if let messages = success as? [PMessage] {
                        single(.success(ChatKitIntegration.convert(messages)))
                    } else {
                        single(.success([]))
                    }
                    return success
                }, { error in
                    single(.success([]))
                    return error
                })
            }
            return Disposables.create {}
        }
    }
    
    open func initialMessages() -> [AbstractMessage] {
        var messages = [AbstractMessage]()
        if let model = model?.messagesModel, let thread = BChatSDK.db().fetchEntity(withID: model.conversation.conversationId(), withType: bThreadEntity) as? PThread {
            if let msgs = BChatSDK.db().loadMessages(for: thread, newest: 25) {
                for message in msgs {
                    if let message = message as? PMessage {
                        messages.insert(CKMessageStore.shared().message(for: message), at: 0)
                    }
                }
            }
        }
        return messages
    }
        
    public static func convert(_ messages: [PMessage]) -> [AbstractMessage] {
        var output = [AbstractMessage]()
        for message in messages {
            output.append(CKMessageStore.shared().new(for: message))
        }
        return output
    }
    
    open func onClick(_ message: AbstractMessage) -> Bool {
        
        if message.messageSendStatus() == .failed {
            if let ck = message as? CKMessage {
                weakVC?.showResendDialog(callback: { result in
                    if result {
                        BChatSDK.thread().send(ck.message)
                    }
                })
                return true
            }
        }
        
        for listener in messageOnClick {
            listener.onClick(for: weakVC, message: message)
        }
        
        if message.messageType() == String(bMessageTypeVideo.rawValue) {
            
            if let message = message as? VideoMessage, let url = message.localVideoURL {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback)
                    let fileURL = URL(fileURLWithPath: url.path)
                    
                    let player = AVPlayer(url: fileURL.absoluteURL)
                    let playerController = AVPlayerViewController()
                    playerController.player = player
                    weakVC?.present(playerController, animated: true, completion: nil)
                } catch {
                    
                }
            }
            
            return true
        }
        if message.messageType() == String(bMessageTypeImage.rawValue) {
            // get the image URL
            
            if let ivc = BChatSDK.ui().imageViewController(), let message = message as? ImageMessage, let url = message.imageURL() {
                ivc.setImageURL(url)
                weakVC?.present(UINavigationController(rootViewController: ivc), animated: true, completion: nil)
            }
            return true
        }
        if message.messageType() == String(bMessageTypeFile.rawValue) {

            return true
        }
        if message.messageType() == String(bMessageTypeLocation.rawValue) {
            if let longitude = message.messageMeta()?[bMessageLongitude] as? NSNumber, let latitude = message.messageMeta()?[bMessageLatitude] as? NSNumber {
                if let nvc = BChatSDK.ui().locationViewController() {
                    nvc.setLatitude(latitude.doubleValue, longitude: longitude.doubleValue)
                    weakVC?.present(UINavigationController(rootViewController: nvc), animated: true, completion: nil)
                }
            }
            return true
        }
        return false
    }
    
    // Typing delegate
    
    open func didStartTyping() {
        if let thread = thread, let indicator = BChatSDK.typingIndicator() {
            indicator.setChatState(bChatStateComposing, for: thread)
        }
    }
    
    open func didStopTyping() {
        if let thread = thread, let indicator = BChatSDK.typingIndicator() {
            indicator.setChatState(bChatStateActive, for: thread)
        }
    }
    
    open func getOptions() -> [Option] {
        var options = [
            galleryOption(),
            locationOption()
        ]
        
        if BChatSDK.videoMessage() != nil {
            options.append(videoOption())
        }

        return options
    }
    
    open func galleryOption() -> Option {
        return Option(galleryOnClick: { [weak self] in
            if let vc = self?.weakVC, let thread = self?.thread {
                
                let pvc = PreviewViewController(mode: .image)
                
                pvc.setDidFinishPicking(images: { [weak self] images in
//                    if let image = image, let imageMessage = BChatSDK.imageMessage() {
//                        imageMessage.sendMessage(with: image, withThreadEntityID: thread.entityID())
//                    }
                    for image in images {
                        if let imageMessage = BChatSDK.imageMessage(), let model = self?.model {
                            imageMessage.sendMessage(with: image, withThreadEntityID: model.conversation.conversationId())
                        }
                    }
                })
                
                vc.present(pvc, animated: true, completion: nil)

                
//                let action = BSelectMediaAction(type: bPictureTypeAlbumImage, viewController: vc, cropEnabled: false)
//                _ = action?.execute()?.thenOnMain({ success in
//                    if let imageMessage = BChatSDK.imageMessage(), let photo = action?.photo {
//
//                        vc.present(PreviewViewController(image: photo), animated: true, completion: nil)
//
//                        if ChatKit.config().imageEditorEnabled {
//                            ZLEditImageViewController.showEditImageVC(parentVC: vc, animate: false, image: photo, editModel: nil) { (resImage, editModel) in
//                                imageMessage.sendMessage(with: resImage, withThreadEntityID: thread.entityID())
//                            }
//                        } else {
//                            imageMessage.sendMessage(with: photo, withThreadEntityID: thread.entityID())
//                        }
//                    }
//                    return success
//                }, nil)
            }
        })
    }
    open func locationOption() -> Option {
        return Option(locationOnClick: { [weak self] in
            if let thread = self?.thread {
                self?.locationAction = BSelectLocationAction()
                _ = self?.locationAction?.execute()?.thenOnMain({ location in
                    if let locationMessage = BChatSDK.locationMessage(), let location = location as? CLLocation {
                        locationMessage.sendMessage(with: location, withThreadEntityID: thread.entityID())
                    }
                    return location
                }, nil)
            }
        })
    }
    
    open func videoOption() -> Option {
        return Option(videoOnClick: { [weak self] in
            if let vc = self?.weakVC, let thread = self?.thread {
                let action = BSelectMediaAction(type: bPictureTypeAlbumVideo, viewController: vc)
                _ = action?.execute()?.thenOnMain({ success in
                    if let videoMessage = BChatSDK.videoMessage(), let data = action?.videoData, let coverImage = action?.coverImage {
                        // Set the local url of the message
                        videoMessage.sendMessage(withVideo: data, cover: coverImage, withThreadEntityID: thread.entityID())
                    }
                    return success
                }, nil)
            }
        })
    }

    open func addSendBarActions() {
            model?.addSendBarAction(sendAction())
            if BChatSDK.audioMessage() != nil {
                model?.addSendBarAction(micAction())
            }
            model?.addSendBarAction(plusAction())
            model?.addSendBarAction(cameraAction())
        }
    
    open func sendAction() -> SendBarAction {
        return SendBarActions.send { [weak self] in
            if let thread = self?.thread {
                if let text = self?.weakVC?.sendBarView.trimmedText(), !text.isEmpty {
                    if let message = self?.weakVC?.replyToMessage(), let m = BChatSDK.db().fetchEntity(withID: message.messageId(), withType: bMessageEntity) as? PMessage {
                        BChatSDK.thread().reply(to: m, withThreadID: thread.entityID(), reply: text)
                        self?.weakVC?.hideReplyView()
                    } else {
                        BChatSDK.thread().sendMessage(withText: text, withThreadEntityID: thread.entityID())
                    }
                    self?.weakVC?.sendBarView.clear()
                }
            }
        }
    }

    open func micAction() -> SendBarAction {
        return SendBarActions.mic { [weak self] in
            self?.weakVC?.showKeyboardOverlay(name: RecordKeyboardOverlay.key)
        }
    }

    open func plusAction() -> SendBarAction {
        return SendBarActions.plus { [weak self] in
            self?.weakVC?.showKeyboardOverlay(name: OptionsKeyboardOverlay.key)
        }
    }

    open func cameraAction() -> SendBarAction {
        return SendBarActions.camera { [weak self] in
            if let vc = self?.weakVC, let thread = self?.thread {
                
                DispatchQueue.main.async {

                    let pvc = PreviewViewController(mode: .image, nibName: nil, bundle: nil)
                    pvc.setDidFinishPicking(images: { [weak self] images in
                        for image in images {
                            if let imageMessage = BChatSDK.imageMessage() {
                                imageMessage.sendMessage(with: image, withThreadEntityID: thread.entityID())
                            }
                        }
                    })

                    vc.present(pvc, animated: true, completion: nil)
                }
                
                
//                let type = BChatSDK.videoMessage() == nil ? bPictureTypeCameraImage : bPictureTypeCameraVideo
//
//                let action = BSelectMediaAction(type: type, viewController: vc)
//
//                AVCaptureDevice.requestAccess(for: .video, completionHandler: { success in
//                    DispatchQueue.main.async {
//                        if success {
//                            _ = action?.execute()?.thenOnMain({ success in
//                                if let imageMessage = BChatSDK.imageMessage(), let photo = action?.photo {
//                                    if ChatKit.config().imageEditorEnabled {
//                                        ZLEditImageViewController.showEditImageVC(parentVC: vc, animate: false, image: photo, editModel: nil) { (resImage, editModel) in
//                                            imageMessage.sendMessage(with: resImage, withThreadEntityID: thread.entityID())
//                                        }
//                                    } else {
//                                        imageMessage.sendMessage(with: photo, withThreadEntityID: thread.entityID())
//                                    }
//                                }
//                                if let videoMessage = BChatSDK.videoMessage(), let video = action?.videoData, let coverImage = action?.coverImage {
//                                    videoMessage.sendMessage(withVideo: video, cover: coverImage, withThreadEntityID: thread.entityID())
//                                }
//                                return success
//                            }, nil)
//                        } else {
//                            self?.weakVC?.view.makeToast(Strings.t(Strings.grantCameraPermission))
//                        }
//                    }
//                })
            }
        }
    }
    
    open func addToolbarActions() {
        model?.addToolbarAction(copyToolbarAction())
        model?.addToolbarAction(trashToolbarAction())
        model?.addToolbarAction(forwardToolbarAction())
        model?.addToolbarAction(replyToolbarAction())
    }
    
    open func copyToolbarAction() -> ToolbarAction {
        return ToolbarAction.copyAction(onClick: { [weak self] messages in
            let formatter = DateFormatter()
            formatter.dateFormat = ChatKit.config().messageHistoryTimeFormat
            
            var text = ""
            for message in messages {
                text += String(format: "%@ - %@ %@\n", formatter.string(from: message.messageDate()), message.messageSender().userName() ?? "", message.messageText() ?? "")
            }
            
            UIPasteboard.general.string = text
            self?.weakVC?.view.makeToast(Strings.t(Strings.copiedToClipboard))

            return true
        })
    }
    
    open func trashToolbarAction() -> ToolbarAction {
        return ToolbarAction.trashAction(visibleFor: { messages in
            var visible = true
            for message in messages {
                if let m = CKMessageStore.shared().message(with: message.messageId()) {
                    visible = visible && BChatSDK.thread().canDelete(m.message)
                }
            }
            return visible
        }, onClick: { [weak self] messages in
            for message in messages {
                _ = BChatSDK.thread().deleteMessage(message.messageId()).thenOnMain({ success in
                    // Seems to be superfluous
//                    _ = self?.model?.messagesModel.removeMessages([message]).subscribe()
                    return success
                }, nil)
            }
            return true
        })
    }
    
    open func forwardToolbarAction() -> ToolbarAction {
        return ToolbarAction.forwardAction(visibleFor: { messages in
            return messages.count == 1
        }, onClick: { [weak self] messages in
            if let message = messages.first as? CKMessage {
                let forwardViewController = ForwardViewController()
                forwardViewController.message = message.message
                self?.weakVC?.present(UINavigationController(rootViewController: forwardViewController), animated: true, completion: nil)
            }
            return true
        })
    }
    
    open func replyToolbarAction() -> ToolbarAction {
        return ToolbarAction.replyAction(visibleFor: { messages in
            return messages.count == 1
        }, onClick: { [weak self] messages in
            if let message = messages.first {
                self?.weakVC?.showReplyView(message)
            }
            return true
        })
    }
    
    // Record view delegate
    open func send(audio: Data, duration: Int) {
        // Save this file to the standard directory
        if let thread = thread {
            BChatSDK.audioMessage()?.sendMessage(withAudio: audio, duration: Double(duration), withThreadEntityID: thread.entityID())
        }
    }

    open func onAvatarClick(_ message: AbstractMessage) -> Bool {
        BChatSDK.db().perform(onMain: { [weak self] in
            if let user = BChatSDK.db().fetchEntity(withID: message.messageSender().userId(), withType: bUserEntity) as? PUser {
                if let vc = BChatSDK.ui().profileViewController(with: user) {
                    self?.weakVC?.navigationController?.pushViewController(vc, animated: true)
                }
            }
        })
        return true
    }

}

open class FileMessageOnClick: NSObject, MessageOnClickListener, UIDocumentInteractionControllerDelegate {
    
    open var documentInteractionProvider : UIDocumentInteractionController?
    open weak var vc: UIViewController?
    
    open func onClick(for vc: ChatViewController?, message: AbstractMessage) {
        if let vc = vc, let message = message as? CKFileMessage, let url = message.localFileURL {
            
            var fileURL = url;
            if !url.isFileURL {
                fileURL = URL(fileURLWithPath: url.path)
            }
            
            self.vc = vc
            documentInteractionProvider = UIDocumentInteractionController(url: fileURL)
            documentInteractionProvider?.name = message.messageText()
            documentInteractionProvider?.delegate = self
            documentInteractionProvider?.presentPreview(animated: true)
        }
    }
    
    open func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self.vc!
    }
    
    open func documentInteractionControllerViewForPreview(_ controller: UIDocumentInteractionController) -> UIView? {
        return self.vc!.view
    }
    
    open func documentInteractionControllerRectForPreview(_ controller: UIDocumentInteractionController) -> CGRect {
        return self.vc!.view.frame
    }
}

open class FileMessageProvider: MessageProvider {
    open func new(for message: PMessage) -> CKMessage {
        return CKFileMessage(message: message)
    }
}

open class FileOptionProvider: OptionProvider {
    
    var action: BSelectFileAction?
    weak var vc: ChatViewController?
    
    open func provide(for vc: ChatViewController, thread: PThread) -> Option {
        self.vc = vc
        
        return Option(fileOnClick: { [weak self] in

            self?.action = BSelectFileAction.init()
            
            if let vc = self?.vc {
                _ = self?.action?.execute(vc).thenOnMain({ success in

                    if let fileMessage = BChatSDK.fileMessage(), let action = self?.action, let name = action.name, let url = action.url, let mimeType = action.mimeType, let data = action.data {
                        let file: [AnyHashable: Any] = [
                            bFileName: name,
                            bFilePath: url,
                            FileKeys.mimeType: mimeType,
                            FileKeys.data: data
                        ]
                        return fileMessage.sendMessage(withFile: file, andThreadEntityID: thread.entityID())
                    }

                    return success
                }, nil)
            }
        })
    }
}

open class Base64MessageOnClick: NSObject, MessageOnClickListener {
        
    open func onClick(for vc: ChatViewController?, message: AbstractMessage) {
        if let vc = vc,
           let message = message as? CKMessage,
           let base64 = message.messageMeta()?["image-data"] as? String,
           let data = NSData(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            
            if let ivc = BChatSDK.ui().imageViewController(), let image = UIImage(data: data as Data) {
                ivc.setImage(image)
                vc.present(UINavigationController(rootViewController: ivc), animated: true, completion: nil)
            }
        }
    }
}
