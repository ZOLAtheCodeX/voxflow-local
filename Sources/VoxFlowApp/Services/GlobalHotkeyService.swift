import Carbon.HIToolbox
import Foundation

enum GlobalHotkeyError: Error {
    case registrationFailed(OSStatus)
    case handlerFailed(OSStatus)
}

final class GlobalHotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private let instanceHotkeyID: UInt32 = UInt32.random(in: 1...UInt32.max)

    func register(
        configuration: HotkeyConfiguration,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) throws {
        unregister()

        self.onPress = onPress
        self.onRelease = onRelease

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased))
        ]

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return noErr }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                if kind == UInt32(kEventHotKeyPressed) {
                    service.onPress?()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    service.onRelease?()
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPointer,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            throw GlobalHotkeyError.handlerFailed(handlerStatus)
        }

        let hotkeyID = EventHotKeyID(signature: OSType(0x5646584C), id: instanceHotkeyID)
        let registrationStatus = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            hotkeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            throw GlobalHotkeyError.registrationFailed(registrationStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotKeyRef = nil
        eventHandlerRef = nil
        onPress = nil
        onRelease = nil
    }

    deinit {
        unregister()
    }
}
