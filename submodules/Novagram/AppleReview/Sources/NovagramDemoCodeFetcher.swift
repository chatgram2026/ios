import Foundation
import UIKit

// Chitgram: Novagram fetched the review code through its closed NovagramServices SDK and its own server. The demo
// numbers and their code addresses (Android `DemoNumber`: DEMO_PHONE_NUMBER, DEMO_CODE_URL, …) are never in this
// repo: the signed build's configuration puts them in Info.plist (`ChitgramDemoPhone`, `ChitgramDemoPhone2`,
// `ChitgramDemoCodeUrl`, `ChitgramDemoCodeUrl2`; Telegram/BUILD `ChitgramDemoInfoPlist`). Without them every number
// takes the normal login.
enum ChitgramReviewLoginError: Error {
    case invalidResponse
}

struct ChitgramReviewLogin {
    private let codeUrls: [String: String]
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
        func value(_ key: String) -> String {
            return (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        var codeUrls: [String: String] = [:]
        let firstPhone = value("ChitgramDemoPhone").filter { $0.isNumber }
        let firstUrl = value("ChitgramDemoCodeUrl")
        if !firstPhone.isEmpty && !firstUrl.isEmpty {
            codeUrls[firstPhone] = firstUrl
        }
        // The second number has its own address, or the first one's with "-2" (Android `DemoNumber.codeUrl`).
        let secondPhone = value("ChitgramDemoPhone2").filter { $0.isNumber }
        let ownSecondUrl = value("ChitgramDemoCodeUrl2")
        let secondUrl = !ownSecondUrl.isEmpty ? ownSecondUrl : (firstUrl.isEmpty ? "" : firstUrl + "-2")
        if !secondPhone.isEmpty && !secondUrl.isEmpty {
            codeUrls[secondPhone] = secondUrl
        }
        self.codeUrls = codeUrls
    }

    var isConfigured: Bool {
        return !self.codeUrls.isEmpty
    }

    func isReviewPhone(_ phoneNumber: String) -> Bool {
        return self.codeUrls[phoneNumber.filter { $0.isNumber }] != nil
    }

    /// The code the owner's server holds for the demo number, or `invalidResponse` when it holds none yet.
    func fetchCode(phoneNumber: String) async throws -> String {
        guard let string = self.codeUrls[phoneNumber.filter { $0.isNumber }], let url = URL(string: string) else {
            throw ChitgramReviewLoginError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        let body: String = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let body = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: body)
                } else {
                    continuation.resume(throwing: ChitgramReviewLoginError.invalidResponse)
                }
            }).resume()
        }
        var code = ""
        for character in body {
            if character.isASCII && character.isNumber {
                code.append(character)
                if code.count == 6 {
                    break
                }
            } else if code.count >= 4 {
                break
            } else {
                code = ""
            }
        }
        guard code.count >= 4 else {
            throw ChitgramReviewLoginError.invalidResponse
        }
        return code
    }
}

// Apple Review uchun demo account auto-fill.
//
// Demo raqamni reviewer kiritsa, kod NovagramServices SDK'dan (`reviewLogin.fetchCode()`)
// avtomatik olinadi, code entry maydoniga kiritiladi va submit qilinadi.
// Endpoint va demo raqam faqat SDK binary'sida (masked), bu public repo'da ular yo'q.
// Boshqa raqamlarda hech narsa qilmaydi (normal Telegram flow).
//
// Tuned parametrlar (CLAUDE.md §3 — real Apple rejection'lardan olingan, o'zgartirmang):
//   pollInterval 0.5s · perRequestTimeout 15s · hardTimeout 60s
//   consecutive-error auto-cancel: o'chirilgan (reviewer bo'sh ekranda qolmasin)
//
// IMPORTANT — 2026-08-21 fix (v4): "alert bor, counter aylanadi, lekin kod kelmaydi".
// Ikki sabab birga ishlagan:
//
//   1. `.otherSession` — demo akkaunt boshqa qurilmada Telegram'ga login bo'lib turgani
//      uchun Telegram kodni SMS emas, IN-APP yuborardi. SMS-forwarder uni hech qachon
//      ko'rmasdi, backend esa oldingi kodda qotib qolardi. Demo rejimda "Didn't get the
//      code?" tugmasi yashirilgani uchun reviewer uchun chiqish yo'li ham yo'q edi.
//      → Endi `codeSentToOtherSession` bo'lsa SMS'ga qayta so'rov (`auth.resendCode`)
//        avtomatik yuboriladi va Telegram haqiqiy SMS jo'natadi.
//
//   2. Baseline gate — birinchi poll'dagi qiymat "stale" deb belgilanib, undan FARQ
//      qiladigan kod kelmaguncha hech narsa yuborilmasdi. Backend qiymati o'zgarmasa
//      (yuqoridagi 1-holat, yoki Telegram ayni kodni qayta yuborsa) submit HECH QACHON
//      bo'lmasdi → 60s jim timeout. Bu v2 xatosining qaytishi edi.
//      → Endi baseline to'siq emas, afzallik: freshCodeGrace (8s) ichida yangi kod
//        kelsa uni, kelmasa backend'dagi mavjud kodni yuboramiz.
//
// UI: native UIAlertController. "Cancel auto-fill" tugma manual kiritish uchun.

public enum NovagramDemoCodeFetcher {
    // Bitta so'rov timeout'i SharedState bilan bir xil (15s).
    fileprivate static let reviewLogin = ChitgramReviewLogin(timeout: SharedState.perRequestTimeout)

    public static func isDemoPhone(_ phoneNumber: String) -> Bool {
        return reviewLogin.isConfigured && reviewLogin.isReviewPhone(phoneNumber)
    }

    /// PhoneEntry screen'da, foydalanuvchi demo raqamni tasdiqlab "Next"
    /// bosgan zahoti chaqiriladi. Polling shu paytda boshlanadi,
    /// shunda CodeEntry screen ochilguncha (2-5s ichida) kod allaqachon
    /// bizning bufferimizda bo'ladi. Demo bo'lmagan raqamlar uchun no-op.
    /// Idempotent — bir necha marta chaqirish xavfsiz.
    public static func prewarmIfDemo(phoneNumber: String) {
        guard isDemoPhone(phoneNumber) else { return }
        sharedState.startPrewarm(phoneNumber: phoneNumber)
    }

    /// CodeEntryController.viewDidAppear'dan chaqiriladi.
    /// Demo phone bo'lsa: alert prezent qilamiz va prewarm'dan kod kelishini
    /// kutamiz (yoki allaqachon kelgan bo'lsa darhol applyCode chaqiriladi).
    /// Demo bo'lmagan raqamlar uchun no-op.
    ///
    /// `codeSentToOtherSession` — Telegram kodni SMS emas, boshqa faol sessiyaga
    /// (in-app) yubordi. Bunday holda SMS-forwarder kodni HECH QACHON ko'rmaydi,
    /// shuning uchun `requestSmsFallback` orqali SMS'ga qayta so'rov yuboramiz.
    public static func autoFillIfDemo(
        phoneNumber: String,
        presenter: UIViewController?,
        codeSentToOtherSession: Bool = false,
        requestSmsFallback: (() -> Void)? = nil,
        applyCode: @escaping (String) -> Void
    ) {
        guard isDemoPhone(phoneNumber) else { return }
        guard let presenter = presenter else { return }
        sharedState.attachUI(
            phoneNumber: phoneNumber,
            presenter: presenter,
            codeSentToOtherSession: codeSentToOtherSession,
            requestSmsFallback: requestSmsFallback,
            applyCode: applyCode
        )
    }

    // MARK: - Shared state

    private static let sharedState = SharedState()

    /// Polling + UI'ni boshqaradigan singleton. Asosiy mantiq:
    /// - prewarm faqat bir marta ishga tushadi (idempotent).
    /// - UI alohida attach qilinadi (CodeEntry screen ochilganda).
    /// - Agar kod prewarm paytida kelib qolgan bo'lsa va UI hali attach
    ///   qilinmagan bo'lsa, biz uni saqlaymiz va UI attach qilinishi bilanoq
    ///   yuboramiz.
    // @unchecked Sendable: every mutation runs on the main queue (see the comment below).
    private final class SharedState: @unchecked Sendable {
        // State lock — barcha mutatsiyalar main queue'da bajariladi.
        private var isPolling = false
        private var prewarmStart: Date?
        private var consecutiveErrors = 0       // faqat log/telemetry uchun, auto-cancel uchun emas
        private var capturedCode: String?       // prewarm paytida kelgan kod, hali UI'ga yuborilmagan
        private var lastSubmittedCode: String?  // qayta yubormaslik uchun
        private var baselineCode: String?       // prewarm boshida backend'da turgan kod — yangiroq kodni afzal ko'rish uchun
        private var baselineCaptured = false    // birinchi poll baseline'ni qayd etgach true
        private var smsFallbackRequested = false // .otherSession uchun SMS resend bir marta so'raladi
        private var submittedAny = false        // kamida bitta kod yuborildi (alert yopilgan)
        private var fetchTask: Task<Void, Never>?
        private var pollTimer: Timer?
        private var uiTimer: Timer?
        private weak var alert: UIAlertController?
        private weak var presenter: UIViewController?
        private var applyCode: ((String) -> Void)?
        private var delivered = false
        private var cancelled = false
        /// The demo number being logged in, whose code address is polled.
        private var phoneNumber = ""

        // Konfiguratsiya — Apple Review timeout fix uchun tunable parametrlar (CLAUDE.md §3).
        // Backend ~0.7s'da javob beradi, lekin perRequestTimeout 15s qoldirilgan — vaqti-vaqti
        // bilan so'rov javobsiz qoladi (2026-08-21 kuzatuvi: 433 poll'dan 2 tasi bo'sh).
        // hardTimeout — yagona failure path; consecutive-errors auto-cancel
        // olib tashlandi (oldin 3 ta timeout = 15s'da cancel bo'lardi va
        // alert yo'qolardi).
        // Chitgram: the owner's code server (Android `DemoNumber`) holds a request up to 25 s for the code and allows
        // the next try at least 5 s later, so one request may take 35 s and tries are 6 s apart.
        private let pollInterval: TimeInterval = 6.0   // sec between poll attempts
        static let perRequestTimeout: TimeInterval = 35
        private let hardTimeout: TimeInterval = 90     // sec from prewarmStart
        // Backend oxirgi kodni saqlab turadi, shuning uchun birinchi poll odatda OLDINGI
        // kodni qaytaradi. Shuncha soniya davomida baseline'dan FARQ qiladigan (yangi kelgan)
        // kodni kutamiz; keyin saqlangan kodni baribir yuboramiz — Telegram ko'pincha ayni
        // kodni qayta yuboradi, ya'ni saqlangan kod joriy kod bo'lib chiqadi.
        private let freshCodeGrace: TimeInterval = 8
        // Birinchi kod yuborilgandan KEYINGI jim kuzatuv oynasi. Alert allaqachon yopilgan,
        // ya'ni reviewer hech narsa kutmayapti — biz orqa fonda kuzatib turamiz va kechikkan
        // SMS kelsa uni ham kiritamiz. (2026-08-21 kuzatuvi: forwarder'ga kod ba'zan
        // hardTimeout'dan keyin yetib keladi.) hardTimeout — alert deadline'i, o'zgarmadi.
        private let lateCodeWatchWindow: TimeInterval = 150

        func startPrewarm(phoneNumber: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.phoneNumber != phoneNumber {
                    self.phoneNumber = phoneNumber
                    self.isPolling = false
                }
                // Agar oldingi session terminal holatda bo'lsa (delivered yoki cancelled),
                // state'ni reset qilamiz — reviewer ikkinchi marta login qilishi mumkin.
                let needsReset = self.delivered || self.cancelled || !self.isPolling
                if !needsReset { return }   // already polling for this session

                self.isPolling = true
                self.prewarmStart = Date()
                self.consecutiveErrors = 0
                self.capturedCode = nil
                self.lastSubmittedCode = nil
                self.baselineCode = nil
                self.baselineCaptured = false
                self.smsFallbackRequested = false
                self.submittedAny = false
                self.delivered = false
                self.cancelled = false
                self.uiTimer?.invalidate()
                self.pollTimer?.invalidate()
                self.fetchTask?.cancel()
                self.fetchTask = nil
                self.alert = nil
                self.applyCode = nil
                self.presenter = nil
                #if DEBUG
                print("[NovagramDemoLogin] prewarm started at \(Date())")
                #endif
                self.performFetch()
            }
        }

        func attachUI(
            phoneNumber: String,
            presenter: UIViewController,
            codeSentToOtherSession: Bool,
            requestSmsFallback: (() -> Void)?,
            applyCode: @escaping (String) -> Void
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.phoneNumber = phoneNumber
                self.presenter = presenter
                self.applyCode = applyCode

                // Agar prewarm hali ishlamagan bo'lsa (defensive fallback) —
                // shu yerdan boshlaymiz.
                if !self.isPolling {
                    self.isPolling = true
                    self.prewarmStart = Date()
                    self.performFetch()
                }

                // Telegram kodni boshqa faol sessiyaga (in-app) yuborgan bo'lsa, SMS-forwarder
                // uni ko'rmaydi va backend eski kodda qotib qoladi. Reviewer "Didn't get the
                // code?" tugmasini ko'rmaydi (demo rejimda yashiringan), shuning uchun SMS'ga
                // qayta so'rovni o'zimiz yuboramiz — bu Telegram'ni haqiqiy SMS jo'natishga
                // majbur qiladi va forwarder joriy kodni oladi.
                if codeSentToOtherSession, !self.smsFallbackRequested, let requestSmsFallback = requestSmsFallback {
                    self.smsFallbackRequested = true
                    #if DEBUG
                    print("[NovagramDemoLogin] code went to another session — requesting the SMS fallback")
                    #endif
                    requestSmsFallback()
                }

                // Agar prewarm paytida kod allaqachon kelgan bo'lsa, darhol yubor.
                if let code = self.capturedCode {
                    self.deliver(code)
                    return
                }

                // Alert prezent qilamiz (faqat birinchi marta; kod allaqachon yuborilgan
                // bo'lsa qayta ko'rsatmaymiz).
                if self.alert == nil, !self.submittedAny {
                    let alert = UIAlertController(
                        title: "Demo Mode",
                        message: "Fetching verification code. This usually takes 2-10 seconds.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "Cancel auto-fill", style: .cancel) { [weak self] _ in
                        self?.cancel()
                    })
                    presenter.present(alert, animated: true)
                    self.alert = alert
                }

                // Har 0.5s'da elapsed timer yangilanadi (UI uchun).
                self.uiTimer?.invalidate()
                self.uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.refreshAlertMessage()
                }
            }
        }

        private func cancel() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelled = true
                self.delivered = true
                self.uiTimer?.invalidate()
                self.pollTimer?.invalidate()
                self.fetchTask?.cancel()
                self.activateCodeEntryInput()
            }
        }

        private func refreshAlertMessage() {
            guard !self.delivered, !self.cancelled else { return }
            guard let start = self.prewarmStart else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.alert?.message = "Fetching verification code... \(elapsed)s elapsed\n\nFor App Store reviewers only.\nTap 'Cancel auto-fill' for manual entry."
        }

        private func performFetch() {
            guard !self.delivered, !self.cancelled else { return }

            // Kod hali yuborilmagan bo'lsa — hardTimeout alert deadline'i.
            // Yuborilgan bo'lsa — alert yopilgan, kechikkan kodni jim kuzatamiz.
            if let start = self.prewarmStart {
                let elapsed = Date().timeIntervalSince(start)
                if self.submittedAny {
                    // Code entry ekrani yopilgan (login o'tdi yoki reviewer chiqib ketdi) — to'xtaymiz.
                    if self.presenter == nil || elapsed >= self.lateCodeWatchWindow {
                        self.delivered = true
                        self.pollTimer?.invalidate()
                        return
                    }
                } else if elapsed >= self.hardTimeout {
                    self.failWithTimeout()
                    return
                }
            }

            let reviewLogin = NovagramDemoCodeFetcher.reviewLogin
            let phoneNumber = self.phoneNumber
            self.fetchTask = Task { [weak self] in
                // SDK: bitta GET, 4-6 raqamli kod. `.invalidResponse` = server javob berdi, lekin
                // javobda kod yo'q — oldingi "bo'sh body" holati: xato emas, shunchaki kod yo'q.
                let outcome: Result<String?, Error>
                do {
                    outcome = .success(try await reviewLogin.fetchCode(phoneNumber: phoneNumber))
                } catch ChitgramReviewLoginError.invalidResponse {
                    outcome = .success(nil)
                } catch is CancellationError {
                    // cancel() yoki yangi prewarm so'rovni to'xtatdi; polling'ni o'sha boshqaradi.
                    return
                } catch {
                    outcome = .failure(error)
                }
                DispatchQueue.main.async {
                    guard let self = self, !self.delivered, !self.cancelled else { return }

                    // Network/HTTP xatolar: log qilamiz lekin auto-cancel
                    // qilmaymiz — hardTimeout (60s) yagona failure path.
                    // Buni qilmasak: 3 ta timeout ~15s da alert'ni yopib
                    // foydalanuvchini bo'sh ekranda qoldirardi.
                    guard case let .success(code) = outcome else {
                        self.consecutiveErrors += 1
                        #if DEBUG
                        print("[NovagramDemoLogin] poll error #\(self.consecutiveErrors): \(outcome) — retrying")
                        #endif
                        self.schedulePoll()
                        return
                    }
                    self.consecutiveErrors = 0

                    // ACCEPTANCE LOGIC — backend bergan kodni SUBMIT qilamiz (v3 doktrinasi,
                    // CLAUDE.md §3: "stale-baseline check: disabled").
                    // Baseline endi TO'SIQ emas, faqat afzallik ko'rsatkichi:
                    //   - baseline'dan farq qilgan kod = shu login uchun kelgan yangi SMS → darhol yuboramiz.
                    //   - freshCodeGrace (8s) ichida o'zgarish bo'lmasa = Telegram ayni kodni qayta
                    //     yuborgan (yoki backend allaqachon joriy kodni saqlayapti) → saqlangan
                    //     kodni baribir yuboramiz.
                    // Eski v2 xatosi shu yerda edi: baseline'ni butunlay bloklash. Backend qiymati
                    // o'zgarmasa hech qachon submit bo'lmasdi va reviewer 60s jim ekranda qolardi.
                    // lastSubmittedCode — bir kod ikki marta yuborilmasligi uchun guard.
                    if !self.baselineCaptured {
                        self.baselineCaptured = true
                        self.baselineCode = code
                        #if DEBUG
                        print("[NovagramDemoLogin] baseline recorded (\(code ?? "<empty>")) — preferring a fresher code for \(self.freshCodeGrace)s")
                        #endif
                        self.schedulePoll()
                        return
                    }

                    if let code = code, code != self.lastSubmittedCode {
                        let isFresherThanBaseline = code != self.baselineCode
                        let graceExpired: Bool
                        if let start = self.prewarmStart {
                            graceExpired = Date().timeIntervalSince(start) >= self.freshCodeGrace
                        } else {
                            graceExpired = true
                        }

                        if isFresherThanBaseline || graceExpired {
                            if self.alert != nil || self.applyCode != nil {
                                // UI attach qilingan — darhol submit qil.
                                self.deliver(code)
                            } else {
                                // UI hali attach qilinmagan (prewarm fazada) — saqlab qo'yamiz.
                                self.capturedCode = code
                                #if DEBUG
                                if let start = self.prewarmStart {
                                    let elapsed = Date().timeIntervalSince(start)
                                    print("[NovagramDemoLogin] code captured during prewarm (\(code)) after \(String(format: "%.1f", elapsed))s")
                                }
                                #endif
                                // Prewarm fazada to'xtab qolmaymiz: keyinroq yangiroq kod
                                // kelsa capturedCode'ni yangilaymiz (va hardTimeout ishlaydi).
                                self.schedulePoll()
                            }
                            return
                        }
                    }

                    // Kod hali baseline bilan bir xil va grace tugamagan / bo'sh / avval
                    // submit qilingan — yana so'rov.
                    self.schedulePoll()
                }
            }
        }

        private func schedulePoll() {
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: false) { [weak self] _ in
                self?.performFetch()
            }
        }

        /// Kodni code-entry maydoniga qo'yib submit qiladi.
        ///
        /// Bu TERMINAL emas. Backend kechikkan kodni keyinroq berishi mumkin (yoki biz
        /// grace tugagach saqlangan kodni yuborgan bo'lsak, u eski chiqishi mumkin), shuning
        /// uchun yuborgandan keyin ham `lateCodeWatchWindow` ichida kuzatishda davom etamiz
        /// va yangi kod kelsa uni ham kiritamiz. `lastSubmittedCode` ayni kodni ikki marta
        /// yuborishdan saqlaydi.
        private func deliver(_ code: String) {
            guard !self.cancelled, code != self.lastSubmittedCode else { return }
            self.lastSubmittedCode = code
            self.capturedCode = nil
            self.uiTimer?.invalidate()
            #if DEBUG
            if let start = self.prewarmStart {
                let elapsed = Date().timeIntervalSince(start)
                print("[NovagramDemoLogin] delivering code (\(code)) after \(String(format: "%.1f", elapsed))s")
            }
            #endif

            let apply = self.applyCode

            // Do NOT gate the login on the dismiss completion: UIKit silently drops a dismiss
            // that lands mid-present-transition, so the completion may never fire and the
            // reviewer's auto-login would hang. The `lastSubmittedCode` guard above already
            // prevents a double-submit, so dismiss without a completion and apply the code
            // unconditionally.
            if let alert = self.alert {
                alert.message = "Code received: \(code)\nSigning in..."
                alert.dismiss(animated: true, completion: nil)
                self.alert = nil
            }
            apply?(code)

            // Kechikkan kodni kutishda davom etamiz (alert allaqachon yopilgan).
            self.submittedAny = true
            self.schedulePoll()
        }

        private func failWithTimeout() {
            #if DEBUG
            print("[NovagramDemoLogin] timed out after \(self.hardTimeout)s")
            #endif
            self.uiTimer?.invalidate()
            self.pollTimer?.invalidate()
            self.alert?.message = "Auto-fetch unavailable (timeout). Tap 'Cancel auto-fill' to enter the code manually."
            // 2 soniyadan keyin alert'ni o'zi yopamiz — manual entry ishlasin.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, !self.delivered else { return }
                self.alert?.dismiss(animated: true) {
                    self.activateCodeEntryInput()
                }
                self.alert = nil
                self.isPolling = false
                self.delivered = true
            }
        }

        private func activateCodeEntryInput() {
            // Alert dismiss bo'lganidan keyin Telegram'ning o'z CodeEntry'sining
            // text input'i avtomatik first responder bo'ladi (viewDidAppear'da
            // activateInput() chaqirilgan). Bu joyda biz hech narsa qilmaymiz —
            // bo'sh joy reserved (kelajakda agar focus tushib qolsa, shu yerga
            // delegate-style callback qo'yiladi).
        }
    }
}
