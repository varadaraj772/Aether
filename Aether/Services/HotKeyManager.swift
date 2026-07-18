import AppKit
import Carbon

@MainActor
final class HotKeyManager {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var callback: (() -> Void)?

  func register(callback: @escaping () -> Void) {
    unregister()
    self.callback = callback

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
          manager.callback?()
        }
        return noErr
      },
      1,
      &eventType,
      selfPtr,
      &eventHandler
    )

    let hotKeyID = EventHotKeyID(signature: OSType(0x41455448), id: 1) // 'AETH'
    RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(cmdKey | shiftKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    callback = nil
  }
}
