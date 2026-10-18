# Android permissions and privacy boundaries

All Android app windows use FLAG_SECURE from Activity creation, independently of
optional App Lock. This blocks ordinary screenshots/recording and task snapshots
on compliant Android versions, including onboarding recovery. It cannot stop a
compromised OS, accessibility abuse, an external camera or a seized unlocked phone.
There is no recovery-word clipboard copy action. Recovery files/QR exports can be
plaintext after an explicit warning and remain the user's responsibility.

MainActivity no longer opts into showing app contents over the device keyguard
or waking the screen itself. Incoming full-screen intents still respect platform
capability and the device lock; answering may require unlocking.

Message/call public lock-screen notification versions contain generic encrypted
message/call text, not message bodies or caller addresses. Private notification
visibility still depends on OS user settings; test on physical devices.

| Permission | Purpose / request boundary |
| --- | --- |
| INTERNET, ACCESS_NETWORK_STATE | Node connections and connectivity; normal permissions |
| USE_BIOMETRIC | User enables/unlocks optional App Lock |
| CAMERA | Opening QR/camera capture or video call |
| RECORD_AUDIO | Starting voice/video capture/call |
| MODIFY_AUDIO_SETTINGS | Call/audio routing |
| READ_EXTERNAL_STORAGE (maxSdkVersion 32) | User opens attachment gallery on older Android |
| READ_MEDIA_IMAGES/VIDEO/VISUAL_USER_SELECTED | User selects gallery media on newer Android |
| BLUETOOTH/BLUETOOTH_ADMIN (maxSdkVersion 30) | Legacy Android Nearby bearer use |
| BLUETOOTH_SCAN/ADVERTISE/CONNECT | Explicitly enabled Nearby BLE |
| ACCESS_FINE/COARSE_LOCATION | Explicit location sharing; legacy discovery/platform requirements |
| NEARBY_WIFI_DEVICES | Explicitly enabled Wi-Fi Direct/Aware Nearby |
| ACCESS_WIFI_STATE/CHANGE_WIFI_STATE/CHANGE_NETWORK_STATE | Nearby Wi-Fi bearer networking |
| POST_NOTIFICATIONS | User enables notifications or active call/service notification |
| USE_FULL_SCREEN_INTENT | Incoming-call UI only, guarded by platform capability; not marketing alerts |
| VIBRATE, WAKE_LOCK | Incoming call/ringing and ongoing service lifetimes |
| FOREGROUND_SERVICE and MEDIA_PLAYBACK/MICROPHONE/CAMERA | Explicit playback/active call; visible notification |
| FOREGROUND_SERVICE_CONNECTED_DEVICE | Explicit sustained Nearby mode; visible notification and stop action |

Nearby starts disabled (`LoomNearbyDtnServiceController._enabled=false`). Enabling
selected bearers requests their permissions and can fail without enabling them;
permission refusal must not authorize a weaker transport. Location sharing,
camera, microphone and notifications are separate user actions. Platform rationale
strings and refusal paths must be checked on each supported Android/OEM version;
a source review is not physical permission-validation evidence. The existing
manifest already bounds legacy storage/Bluetooth permissions and disables backup.
