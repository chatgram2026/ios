# Chitgram feature map: Android → iOS

Every Chitgram feature, where it sits on Android, and where it goes in Telegram-iOS. The owner's rule:
"funksiyalari joylashuvi android bilan bir xil bo'lsin" — the same settings section, rows and order, the same
menus and buttons, the same names. Written 2026-11-04 from the Android tree at
`C:\Users\shohj\Documents\Chatgram` (branch `feature/voice-roulette`, 6e588cbb2: 108 files, 28.7k lines under
`org/fenixuz/`, 247 `Chitgram:` hooks in 50 upstream files).

Numbers in `[]` are Android string ids (`org/fenixuz/utils/LanguageCode.kt`, `TitleLanguages(id, en, uz, ru)`,
ids 0…809). iOS reads the same table with the same ids (see "Strings" below), so a row is named by its id on both
platforms. The Uzbek text is given because it is what the owner sees.

## How the iOS code is laid out

The rule from the Android tree carries over: Chitgram code lives in its own modules, upstream files change only at
small hooks commented `// Chitgram:`.

| Module (`submodules/…`) | Holds | Depends on |
|---|---|---|
| `ChitgramCore` | Settings store (app-group `UserDefaults` suite `chitgram`, so the notification extension sees it), switches read by the hooks (ghost, deleted/edited saving, APK shield, ads…), strings table. Foundation only. | — |
| `ChitgramEngine` | Network-side logic that needs `TelegramCore`: ghost reads, auto answer, auto-accept, auto messenger, Premium from the Stars history, cloud sync, keyword watch, admin folders, join-all. | ChitgramCore, TelegramCore, SwiftSignalKit |
| `ChitgramSettings` | The Chitgram section and the "Sozlamalar" screen (ItemListUI), per-chat tools, tab bar settings, about, chat finder. | ChitgramCore, ChitgramEngine, ItemListUI, AccountContext |
| `ChitgramPremium` | Premium screen and sheets, badges. | ChitgramEngine, … |
| `ChitgramRoulette` | Voice roulette and chat roulette (WebSocket + the WebRTC that tgcalls already ships). | ChitgramCore, TgVoipWebrtc |
| `ChitgramAutoPost` | Auto messenger screens. | ChitgramEngine, ItemListUI |
| `ChitgramLock` | Secret folder, per-chat lock, passcode screens (reusing `PasscodeUI`). | ChitgramCore, PasscodeUI |

TelegramCore must not import UIKit (it is shared with the Mac app upstream), so its hooks only read
`ChitgramCore` switches and call closures that `ChitgramEngine` installs at launch.

## Strings

- `build-system/chitgram/strings.py` reads the Android `LanguageCode.kt` and writes
  `submodules/ChitgramCore/Resources/ChitgramStrings.json` (`[{id, en, uz, ru}]`, the same ids). Re-run it when the
  Android table grows; never renumber.
- `ChitgramStrings.get(id)` picks the language the way Android does: the app language (`uz`, `ru`, otherwise `en`),
  taken from `presentationData.strings.primaryComponent.languageCode`.
- Telegram's own strings in Uzbek come from Telegram's server language pack (Settings ▸ Language), as on Android.

## 1. Settings tab ▸ the "Chitgram" section

Android (`SettingsActivity.fillItems`): a section headed **Chitgram**, directly under the accounts block and above
Telegram's own rows. iOS: `PeerInfoSettingsItems.swift` (`settingsItems`), a new `SettingsSection.chitgram` right after
`.accounts`; taps go through `PeerInfoScreenSettingsActions.swift` (`openSettings`). Rows in this order:

| # | Row | Android | iOS |
|---|---|---|---|
| 1 | Chitgram Premium [427] | `premium/ChitgramPremiumScreen` | `ChitgramPremium` screen |
| 2 | Ovozli ruletka / Voice roulette [698] | `roulette/RouletteActivity` | `ChitgramRoulette` voice screen |
| 3 | Chatruletka / Chat roulette [787] | `roulette/ChatRouletteActivity` | `ChitgramRoulette` video screen |
| 4 | Sozlamalar / Settings [236] | `ui/FenixSettings` (section 2) | `ChitgramSettings` screen |
| 5 | Ilova mavzusi / App theme [120] | Telegram's ThemeActivity | upstream `ThemeSettingsController` (Appearance) |
| 6 | Ilova keshi / App cache [121] | Telegram's CacheControlActivity | upstream `StorageUsageScreen` |
| 7 | Suhbat topuvchi / Chat finder [123] | `ui/chat_finder/ChatFinder` | `ChitgramSettings` chat finder |
| 8 | Ilova haqida / About [355] | `ui/about/AboutScreen` | `ChitgramSettings` about |

Icons: the same colour pairs as Android (`SettingCell.Factory.of(id, top, bottom, …)`), drawn as iOS settings icons.

Also in the Settings tab, Accounts block: **Add Account** row while a slot is free, limited by Chitgram Premium
(`premium/AccountLimit`: free count vs. Premium count). iOS: the existing `Settings_AddAccount` row (id 100 in
`.accounts`) and every other add-account entry go through one `ChitgramEngine.AccountLimit.addAccount`. Each
account row also gets a per-account notification switch (Android `AccountCell`). iOS limit today is 3 accounts
(`maximumNumberOfAccounts`); Chitgram raises it as Android does.

## 2. Chitgram ▸ Sozlamalar (`FenixSettings`)

Android: `ui/FenixSettings.kt`, title [236], toolbar "?" replays the feature tour (`ui/onboarding/FenixTour`, auto-runs
once on first open). Long-press on a feature row offers to copy/send its `tg://chatgram_settings/<key>` link; opening
the link scrolls to the row and flashes it. iOS: `ChitgramSettings/ChitgramSettingsController.swift`, an ItemList
screen with the same sections, rows and order; the deep link is handled in `openResolvedUrl` (hook in
`TelegramUI/Sources/OpenResolvedUrl.swift`) and the app's URL parser (`UrlHandling`).

| Section header | Row (id) | Kind | What it does | iOS hook |
|---|---|---|---|---|
| Hikoya Sozlamalari [135] | Hikoyalarni yashirin ko'rish [232] / sub [233] | switch | View stories without being listed as a viewer (`GhostStory`). | TelegramCore story seen request (`_internal_markStoryAsSeen`) |
| | Hikoyalarni yashirish [136] / [137] | switch | Hide the stories tray in the chat list (`StoryUtil`). | `ChatListController` story subscriptions |
| | Hikoyani yuklab olish [297] / [298] | switch | "Save story" in the story viewer's ⋯ menu for any story (`StoryDownload`). | `StoryItemSetContainerComponent` more menu |
| Xabarlar [234] | Tahrirlangan xabarlarni saqlash [23] / [72] | switch | Keep earlier versions of edited messages (`EditMessage`, `archive/ChitgramArchive`). | TelegramCore update replay (`AccountStateManagementUtils`, `.EditMessage`) |
| | O'chirilgan xabarlarni saqlash [31] / [235] | switch | Keep messages deleted for everyone (`DeletedMsg`). | TelegramCore replay (`.DeleteMessages*`) |
| | Media nusxasi [556] / [557] (only while saving is on) | switch | Also keep a copy of the media, with size. | `ChitgramEngine` archive |
| Yuklab olish [237] | Avto yuklashni to'xtatish [183] / [196] | switch | Turn off auto-download on every network. | upstream `MediaAutoDownloadSettings` |
| Avtomatik javob [228] | Avtomatik javob [228] / [239] | switch | Reply once to the first message of each chat (`ui/auto_answer`). | `ChitgramEngine` on incoming messages |
| | Javob matni [238] | button | Plain text editor for the reply. | `ChitgramSettings` |
| | Kalit so'z kuzatuvchisi [568] | button | Words to watch for in any chat (`keywords/`). | `ChitgramSettings` + `ChitgramEngine` |
| Maxfiylik [244] | Ghost rejimi [32] / [245] | switch | Master switch: hide reads, online, typing, uploads (`GhostVariable`). | TelegramCore: read history, presence, typing, upload activity |
| | (only while master is off) O'qilganlik [558]/[559], Online [560]/[561], Yozayapti [562]/[563], Yuklayapti [564]/[565] | switches | Each signal on its own. | same hooks |
| | Ghost tugmasi [342] / [343] | switch | Ghost toggle button on the chat list toolbar. | `ChatListController` navigation bar |
| | Telegram reklamasini yashirish [566] / [567] | switch | Never request sponsored messages (`SponsoredAds`). | TelegramCore `AdMessagesHistoryContext` |
| | Yashirin suhbat [213] / [217] | switch | Create/remove the secret-folder passcode (`ui/secret_chat`). | `ChitgramLock` |
| Suhbat qulfi [252] (only with a common password) | Umumiy parolni o'zgartirish [251] | button | Change the common chat-lock password. | `ChitgramLock` |
| Tasdiqlash dialoglari [190] | Stiker [210]/[191], Ovozli xabar [211]/[192], GIF [212]/[193] | switches | Ask before sending. | sticker/GIF send paths in `ChatController`, voice in `ChatRecordingPreview` |
| Dumaloq video [353] | Old kamera [113] / [354] | switch | Round videos start on the front (on) or rear camera. | `VideoMessageCameraScreen` |
| Xabar maydoni [380] (only with a speech recogniser) | Mikrofon [381] / [382] | switch | Dictation mic in the composer. | `ChatTextInputPanelNode` |
| Jild ikonkalari [240] | Jild ikonkalari [240] / [241] | switch | Folder tabs as icons (`ui/create_folder_dialog/FolderIcons`). | `ChatListFilterTabContainerNode` |
| | Jild tablarini yashirish [260] / [261] | switch | Hide the folder tabs row (`HideTabs`). | `ChatListControllerNode` |
| | Pastki panel [406] | button | Tab bar editor (`ui/tab_bar/TabBarSettings`). | `ChitgramSettings` → `TelegramRootController` |
| | Adminlik papkalari [391] / [392] | switch | Four server folders: groups/channels owned/administered (`folders/AdminFolders`), with confirmations [397]/[402]. | `ChitgramEngine` (`updateChatListFiltersInteractively`) |
| | Papkalarni yangilash [398] (only when on) | button | Rebuild them. | same |
| Kanallar [262] | A'zolik so'rovlarini avto-qabul [263] + state | button | Screen with the switch and the chats (`ui/join_requests/AutoAcceptActivity`). | `ChitgramSettings` + engine on `updatePendingJoinRequests` |
| Xabar eslatmasi [269] | O'qilmagan xabar eslatmasi [270] / [271] | switch | Remind with a sound when a message stays unread (`MessageReminder`). | local notification (`UNUserNotificationCenter`) |
| | Kutish vaqti [272] | picker | Minutes. | |
| | Ovoz [274] | picker | Sound. | |
| Xavfsizlik [318] | APK fayllarni bloklash [378] / [379] | switch | Incoming .apk shown as a red warning card (`ApkShield`, `ApkCard`). | message bubble for documents (`ChatMessageFileBubbleContentNode`) |

## 3. Chat list (Android `DialogsActivity`, iOS `ChatListUI/ChatListController.swift`)

| Feature | Android place | iOS place |
|---|---|---|
| Ghost toggle button | Action bar, next to search/lock (`ghostItem`, shown when [342] is on) | A navigation bar button beside compose |
| Main menu: Avto xabarchi [463], Ovozli ruletka [698], Chatruletka [787], Hikoyalarni yashirish (when enabled) | Header ⋮ menu (`showItemOptions`), after Night mode, before New group | iOS has no ⋮ here: a `more` navigation button (Telegram-iOS's own `id: "more"` style) opening a context menu with the same items in the same order |
| Proxy row always present | ⋮ menu | iOS keeps proxy in Settings and the title's connection status; noted, no change |
| Select all | Selection mode menu | `ChatListSelection` toolbar |
| Add to / remove from secret chat [215]/[216] | Selection mode ⋮ menu (only with a passcode) | Selection toolbar / chat context menu (`ChatContextMenus.swift`) |
| Open the secret folder | Long-press on the action bar title | Long-press on the chat list title |
| Ghost chat preview | Long-press on a chat's avatar: bottom sheet that reads without receipts (`ui/chat_preview`) | iOS long-press already opens a peek preview; make it receipt-free (hook in `ChatContextMenus.swift` / preview `ChatController` mode) |
| Hide folder tabs, folder icons | Folder tab row | `ChatListFilterTabContainerNode` |
| Chitgram Premium emoji next to the title | Tap on it opens the badge picker | Title view in `ChatListController` |
| Sponsored channel in search | Top of search results (`ads/`) | `ChatListSearchListPaneNode` |
| Keep admin folders current | On resume | `ChitgramEngine` on launch/foreground |
| In-app rating | After a few days of use (`AppRating`) | `SKStoreReviewController.requestReview` |

## 4. Chat screen (Android `ChatActivity` ⋮ menu → iOS profile "More" menu)

On Android these items sit in the chat header's ⋮ menu. iOS chats have no ⋮ menu: Telegram-iOS keeps the same kind
of actions (search, mute, clear history, delete) under the profile's **More** (⋯) button, so Chitgram's items go there,
in Android's order, after Translate. iOS: `PeerInfoScreenPerformButtonAction.swift` (`.more`).

| Item | Android | Shown when |
|---|---|---|
| Matn uslubi / Text style [166] | `ui/text_style_dialog` (default style applied on send) | always |
| Chat id (tap copies) | row labelled with the id | always |
| Chitgram Sozlamalar [305] | per-chat tools (`ui/auto_text/ChatFenixSettings`): Bir martalik ovoz va video [306]/[307], Avtomatik matn qo'shish [300]/[301], Matnni tahrirlash [302], Suhbatni qulflash [246]/[247] | not secret chats |
| Ovozni matnga o'girish / Voice to text [308] | dictation + translate sheet (`ui/voice_translate`) | can send |
| Avtomatik tarjima / Auto-translate [324] | per-chat outgoing language (`ui/auto_text/AutoTranslatePicker`) | can send |
| A'zolik so'rovlari / Join requests [279] | bulk approve/decline sheet (`ui/join_requests/JoinRequestsSheet`) | admin with invite right |
| Barcha akkauntlar bilan qo'shilish [294] | join on every account (`JoinAllAccounts`) | public channel/group, >1 account |

Elsewhere in the chat:

| Feature | Android | iOS |
|---|---|---|
| Maxsus uzatish / Special forward [255] | message menu + selection bar: forward hiding the sender | `ChatInterfaceStateContextMenus.swift`; selection panel `ChatMessageSelectionInputPanelNode` (iOS already has "hide sender" in the forward options; this is the one-tap shortcut) |
| Avto xabarchiga qo'shish [483] | message menu: new auto-messenger task from this message | `ChatInterfaceStateContextMenus.swift` |
| Tahrirlar tarixi / Edit history [390] | message menu on an edited message (`ui/message_history`) | `ChatInterfaceStateContextMenus.swift` |
| Old versions in the bubble | struck-through quote above the text (`EditPreview`) | text bubble (`ChatMessageTextBubbleContentNode`) |
| "Deleted" mark | deleted messages stay with a mark | message date/status node |
| Go to first message (↑) | button mirroring the ↓ button | `ChatHistoryNavigationButtons` |
| Locked chat | passcode screen on open (`Password`, `SecretLockScreenDialog`) | `ChitgramLock` before `ChatController` is shown |
| `.heart` effect | send `.heart` → ❤️ that cycles colours on your side | send path in `ChatController` |
| Auto text signature | appended on send / caption edit | send path (`ChatControllerLoadDisplayNode` → `sendMessages`) |
| Auto-translate on send | first Send translates, second sends | `ChatTextInputPanelNode` send |
| Dictation mic | composer button (right attach row) | `ChatTextInputPanelNode` accessory buttons |
| Round video camera | front/rear from the setting | `VideoMessageCameraScreen` |
| One-time voice/video default | per chat | `ChatRecordingPreview` / view-once default |
| Confirm sticker/voice/GIF | before send | send paths |
| Big files (over 2/4 GB) | sent as .001/.002 parts, opened as one (`bigfile/`) | attachment send + `openChatMessage` |
| Blocked .apk card | red card with a delayed "show anyway" | file bubble |
| Translate shown by default | per-message Translate in private chats and groups | translate settings default |

## 5. Media viewer, stories, share sheet, profile

| Feature | Android | iOS |
|---|---|---|
| Matnni skanerlash / Scan text [330] | PhotoViewer ⋮ menu, images only (`ui/photo_to_text`): copy / translate / share | gallery more menu (`ChatItemGalleryFooterContentNode`), using upstream's on-device text recognition (`ImageContentAnalysis`, `RecognizedTextSelectionNode`) |
| Send gallery video as a round video | toggle next to mute in the editor | media editor (`MediaEditorScreen`) |
| Save any story | story ⋯ menu (with [297]) | `StoryItemSetContainerComponent` |
| Share sheet categories | under search: All, folders, Personal, Groups, Channels, Bots; select a whole category (free/Premium cap [628]); "Iqtibos" and "Sarlavha" switches; paced sending past N chats (`share/`) | `ShareControllerNode` / `SharePeersContainerNode` |
| Chitgram Premium badge | animated Chitgram mark before the name, emoji after it; tap own → badge picker, others → Premium sheet (`badge/`) | emoji status / verification slots (`EmojiStatusComponent`), profile header (`PeerInfoHeaderNode`) |

## 6. Login (Android `LoginActivity`, iOS `AuthorizationUI`)

| Feature | Android | iOS |
|---|---|---|
| "Chitgram" title top-left | phone entry page | `AuthorizationSequencePhoneEntryControllerNode` |
| QR login button | top-right of phone entry (`ui/qr_login`) | same corner; `auth.exportLoginToken` |
| Log in with bot token | link under the phone field (`ui/bot_login`) | same place; `auth.importBotAuthorization` |
| Demo numbers for App Review | code fetched from the owner's server (`DemoNumber`) | code entry; values only in the CI secrets / local config, never committed |
| Account counter | +1 per completed login (`analytics/`) | after `AuthorizationSequenceController` completes |

## 7. Bottom tab bar (Android `MainTabsActivity`, iOS `TelegramRootController`)

`utils/ChatgramTabs` + `ui/tab_bar/TabBarSettings`: order, visible tabs, labels on/off, selected-tab style, an extra
button (search, new message…), the tab the app opens on. Calls follows Telegram's own switch. iOS:
`TelegramRootController.swift` builds the tab list; the editor is in `ChitgramSettings`.

## 8. Roulettes

Backend `wss://chatgram.uz/roulette/ws` (Cloudflare, another team), protocol in the Android `CLAUDE.md`.

| | Android | iOS |
|---|---|---|
| Voice roulette | `RouletteActivity` (call-screen look, design "8"), foreground service + notification | `ChitgramRoulette`; `CallKit`-free audio session (`AVAudioSession` voiceChat), background audio while in a call |
| Chat roulette | `ChatRouletteActivity` (design 6 "Chat birinchi"): header controls, two 2:3 tiles, chat on the wallpaper, consent card, Stop/Next | same layout |
| Entry points | Settings ▸ Chitgram rows 2–3, chat list ⋮ menu, notification `tg://chatgram_roulette` | Settings ▸ Chitgram, chat list "more" menu, `tg://chatgram_roulette` |
| WebRTC | Telegram's bundled `org.webrtc`, relay only, Opus factories added natively | `third-party/webrtc` already in the app (tgcalls); a small ObjC++ wrapper creating a `RTCPeerConnectionFactory` with relay-only ICE |
| Device id / integrity | random UUID; Play Integrity | random UUID in Keychain; App Attest later (server has `REQUIRE_INTEGRITY=0`) |

## 9. Things with no screen of their own

| Feature | Android | iOS |
|---|---|---|
| Settings sync across devices | `cloud/ChitgramCloud`, `cloud/SavedCloud`: scheduled messages a year ahead in Saved Messages, gzip, newest wins per key | same format, so Android and iOS share one account's settings |
| Auto messenger | `autopost/` (Telegram scheduled messages, paced, ≤80 per chat, free 1 task/2 chats/60 min, Premium 10/100/10 min); task list reached from the chat list menu and the Premium page; tasks synced through the cloud | `ChitgramAutoPost`; same storage format |
| Premium | `premium/ChitgramPremium`: prices from the @chitgram_org pin (`1-400 12-4000`), paid ⭐ reaction, confirmed from the user's own Stars history | same; `payments.getStarsTransactions` through `TelegramEngine` |
| App notices | `update/AppUpdate`, `MaintenanceView`: maintenance / required / optional update lines in the channel pin | same pin; "update" opens the App Store |
| Ghost reads kept locally | `GhostRead`: read marks not sent are remembered so old messages never re-notify; flushed when ghost ends | TelegramCore read-state hook + notification extension check |
| Deleted/edited archive | `archive/ChitgramArchive`: whole messages in its own database | own SQLite file in the account folder |
| Auto-accept join requests | on `updatePendingJoinRequests` | TelegramCore update hook |
| Auto-proxy for censored regions | `proxy/RegionProxyManager` (Firebase Remote Config, Russia only) | needs Firebase on iOS; later |
| Mini apps without a broken proxy | `web/WebProxyFix` | WKWebView ignores the system proxy differently; check before porting |
| Analytics counters | `analytics/AnalyticsRemote` (Firestore, install de-dup by Android ID) | Firestore REST with `identifierForVendor`; must be declared in App Privacy |
| Sponsored search ad | `ads/` (search query + user id to the ads backend) | same API; declare in App Privacy |

## Not ported

- **Stranger shield** is in `README.md` and `docs/FEATURES-uz.md` (items 43–45) but no code for it exists in the
  current Android tree; ask the owner before building it.
- `ui/ghost_menu/GhostMenu.kt` and `ui/analytics_screen/AnalyticsScreen.kt` exist but nothing opens them on Android.
- Huawei/RuStore build variants, Google Play rating card (iOS uses `SKStoreReviewController`).

## iOS limits to tell the owner about

- iOS does not run the app in the background. Auto answer, keyword watch, auto-accept and the reminder work while the
  app is open or just closed; the auto messenger is unaffected (its sends are queued on Telegram's server).
- App Store review: roulettes (guideline 1.2) and Premium through Stars (3.1.1) are the owner's accepted risks.
  Saving any story, saving deleted messages and ghost mode are the same as several App Store Telegram clients, but
  can still be questioned.
- Live Text already exists on iOS; "Scan text" reuses it.

## Porting order

The order of the Settings ▸ Chitgram section, then the Sozlamalar rows top to bottom, then the chat-level items.
Each step is built in CI before the next one starts.

1. Branding: name "Chitgram", icons, bundle id, strings table, the Chitgram section with its rows (screens empty).
2. Sozlamalar screen, row by row: stories, edited/deleted saving, auto-download, auto answer + keyword watch, ghost
   mode (+ toolbar button, ads), secret folder + chat lock, confirmations, round video camera, mic, folder icons /
   hide tabs / tab bar / admin folders, auto-accept, reminder, APK shield.
3. App theme, app cache, chat finder, about.
4. Chat list menu, chat "More" menu items, message menu items, composer items, media viewer, share sheet.
5. Cloud sync, Premium (and the limits it lifts: accounts, auto messenger, share bulk, keyword count), badges.
6. Auto messenger.
7. Voice roulette, then chat roulette.
8. Login extras (QR, bot token, demo numbers), notices, analytics, sponsored search.
