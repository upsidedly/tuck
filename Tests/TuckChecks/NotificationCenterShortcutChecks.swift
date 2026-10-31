import Foundation
import TuckCore

func notificationCenterShortcutsRespectSystemOverrides() {
    let systemDefault = NotificationCenterShortcut(hotKeys: [:])
    precondition(systemDefault?.keyCode == 45 && systemDefault?.flags == 0x800000)

    let custom: [String: Any] = ["163": [
        "enabled": true, "value": ["parameters": [65535, 46, 0x120000]]
    ]]
    let parsed = NotificationCenterShortcut(hotKeys: custom)
    precondition(parsed?.keyCode == 46 && parsed?.flags == 0x120000)
    precondition(NotificationCenterShortcut(hotKeys: ["163": ["enabled": false]]) == nil)
    precondition(NotificationCenterShortcut(hotKeys: ["163": ["enabled": true]]) == nil)
    precondition(NotificationCenterShortcut(hotKeys: ["163": [
        "enabled": true, "value": ["parameters": [65535, -1, 0]]
    ]]) == nil)
}
