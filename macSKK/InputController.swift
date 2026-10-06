// SPDX-FileCopyrightText: 2022 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import InputMethodKit

// AppleのAPIドキュメントにはIMKのコールバックがメインスレッドで呼ばれるとは明記されていないため、
// nonisolatedなコールバックからはmainSyncを経由してMainActorで処理を実行する。
// メインスレッドで呼ばれた場合はそのまま実行し、そうでない場合は警告ログを出してメインスレッドに同期実行する。
@MainActor
@objc(InputController)
class InputController: IMKInputController {
    /// 入力元のアプリケーション情報
    struct TargetApplication {
        // Android StudioのAndroidエミュレータのようにbundle identifierをもたないGUIアプリケーションはnil
        let bundleIdentifier: String?
        // FIXME: NSRunningApplicationから取得するので、表示名が取れないときもあるかもしれない?
        let localizedName: String?
    }

    private let stateMachine = StateMachine()
    private var targetApp: TargetApplication! = nil
    private var cancellables: Set<AnyCancellable> = []
    // Global.completionPanelが@MainActorなためnonisolatedなinitのプロパティ初期化式では生成できない。
    // setUp(inputClient:)で初期化する。
    private var completionPresenter: CompletionPresenter!
    private static let notFoundRange = NSRange(location: NSNotFound, length: NSNotFound)
    /// 変換候補として選択されている単語を流すストリーム
    private let selectedWord = PassthroughSubject<Word.Word?, Never>()
    /// 入力モードを表示するときに流すストリーム。
    private let displayInputModePanel = PassthroughSubject<InputMode, Never>()
    /// setValueで呼ばれたときに流すストリーム。非同期処理するために使用。
    private let inputModeChangedOutside = PassthroughSubject<InputMode, Never>().throttle(for: 0.1, scheduler: DispatchQueue.global(), latest: true)
    /// 入力を処理しないで直接入力させるかどうか
    private var directMode: Bool = false
    /// モード変更時に空白文字を一瞬追加するワークアラウンドを適用するかどうか
    private var insertBlankString: Bool = false
    /// 1文字目を常に未確定扱いするワークアラウンドを適用するかどうか
    private var treatFirstCharacterAsMarkedText: Bool = false
    /// 空のときには▽▼を表示するワークアラウンドを適用するかどうか
    private var showMarkerWhenEmpty: Bool = false

    /// nonisolatedなIMKコールバックから@MainActorな処理を同期実行するためのヘルパー。
    /// IMKのコールバックは経験上メインスレッドで呼ばれるが、APIドキュメントには明記されていないため、
    /// メインスレッド以外から呼ばれた場合は警告ログを出した上でメインスレッドに同期実行する。
    ///
    /// self(非Sendable)の受け渡しもここで行うため、workは@MainActor隔離された状態のselfを引数で受け取る。
    /// 呼び出し側でnonisolated(unsafe)を書く必要があるのはIMK由来の引数などself以外の値だけ。
    @discardableResult
    private nonisolated func mainSync<T: Sendable>(function: String = #function, _ work: @MainActor (InputController) -> T) -> T {
        // InputControllerはIMKInputControllerを継承しSendableでないため、selfを退避してクロージャへ渡す。
        nonisolated(unsafe) let this = self
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work(this) }
        } else {
            logger.warning("\(function, privacy: .public) がメインスレッド以外から呼び出されました。メインスレッドで同期実行します。")
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { work(this) }
            }
        }
    }

    // IMKInputControllerのイニシャライザはnonisolatedなので、オーバーライドもnonisolatedにする必要がある。
    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        nonisolated(unsafe) let inputClient = inputClient
        mainSync {
            $0.setUp(inputClient: inputClient)
        }
    }

    private func setUp(inputClient: Any!) {
        guard let textInput = inputClient as? any IMKTextInput else {
            return
        }
        expInitClient = textInput
        if let bundleIdentifier = textInput.bundleIdentifier() {
            targetApp = TargetApplication(bundleIdentifier: bundleIdentifier, localizedName: nil)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                if let localizedName = app.localizedName {
                    targetApp = TargetApplication(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
                    break
                }
            }
        } else {
            logger.log("Bundle Identifierをもたないアプリケーションから接続されました")
            targetApp = TargetApplication(bundleIdentifier: nil, localizedName: nil)
        }

        stateMachine.inputMethodEvent.sink { [weak self] event in
            if let self {
                switch event {
                case .fixedText(let text):
                    if stateMachine.state.inputMode != .direct && textInput.bundleIdentifier() == "com.jetbrains.intellij" {
                        // AquaSKKと同様に、非確定文字列に確定予定文字列を先に表示する
                        textInput.setMarkedText(
                            text,
                            selectionRange: NSRange(location: text.count, length: 0),
                            replacementRange: Self.notFoundRange)
                    }
                    textInput.insertText(text, replacementRange: Self.notFoundRange)
                case .markedText(let markedText):
                    let showMarker: Bool
                    if showMarkerWhenEmpty && !Global.showMarkedTextMarker {
                        showMarker = markedText.elements.compactMap(\.text).allSatisfy(\.isEmpty)
                    } else {
                        showMarker = Global.showMarkedTextMarker
                    }
                    let attributedText = markedText.attributedString(showMarker)
                    let cursorRange: NSRange = markedText.cursorRange(showMarker) ?? Self.notFoundRange
                    // Thingsのメモ欄などで最初の一文字をShift押しながら入力すると "▽あ" が直接入力されてしまうことがあるのを回避するワークグラウンド
                    if case .markerCompose = markedText.elements.first, markedText.elements.count == 2,
                       case let .plain(text) = markedText.elements[1], text.count == 1 {
                        textInput.setMarkedText(NSAttributedString(MarkedText([.markerCompose]).attributedString(showMarker)),
                                                selectionRange: cursorRange,
                                                replacementRange: Self.notFoundRange)
                    }
                    textInput.setMarkedText(NSAttributedString(attributedText), selectionRange: cursorRange, replacementRange: Self.notFoundRange)
                case .undoFixedText(let markedText, let replacementRange):
                    // 確定アンドゥ。すでにクライアントに送った確定文字列を未確定文字列で置き換える。
                    // ChromiumのWebコンテンツやターミナルでは範囲指定が無視されてキャレット位置に置かれるため、
                    // 送り元のStateMachineが書き込んだ位置を読み直して判定する。
                    //
                    // 判定に使うのでマーカー (▽▼) は利用者の設定によらず必ず表示する。
                    // マーカーがないと確定済み文字列と同じ文字列になりうるので、
                    // 書き込み後の読み取りに古い内容を返すクライアント (ChromiumのWebコンテンツ) で
                    // 置けたかどうかを判別できない。置けた場合はStateMachineがこのあと設定どおりに表示し直す
                    let expString = NSAttributedString(markedText.attributedString(true))
                    let expSelection = markedText.cursorRange(true) ?? Self.notFoundRange
                    logger.log("EXP undoFixedText: setMarkedText(\"\(expString.string, privacy: .public)\", selectionRange: \(expRange(expSelection), privacy: .public), replacementRange: \(expRange(replacementRange), privacy: .public)) elements=\(String(describing: markedText.elements), privacy: .public) attrs=\(String(describing: expString), privacy: .public)")
                    textInput.setMarkedText(expString,
                                            selectionRange: expSelection,
                                            replacementRange: replacementRange)
                case .replaceFixedText(let text, let replacementRange):
                    // 確定アンドゥのフォールバック。
                    // すでにクライアントに送った確定文字列を別の確定文字列で置き換える。
                    // insertTextに空文字列を渡すと範囲指定ごと無視される (macOS 26.6で確認) ので、
                    // 消すのではなく別の確定文字列で置き換えている
                    textInput.insertText(text, replacementRange: replacementRange)
                case .modeChanged(let inputMode):
                    // KittyやAlacrittyなど、q/lによるモード切り替えでq/lが入力されたり、C-jで改行が入力されるのを回避するワークアラウンド
                    // AquaSKKの空文字列挿入を参考にしています。
                    // https://github.com/codefirst/aquaskk/blob/4.7.5/platform/mac/src/server/SKKInputController.mm#L405-L412
                    if self.stateMachine.state.specialState == nil && self.insertBlankString {
                        textInput.setMarkedText(String(format: "%c", 0x0c), selectionRange: Self.notFoundRange, replacementRange: Self.notFoundRange)
                        textInput.setMarkedText("", selectionRange: Self.notFoundRange, replacementRange: Self.notFoundRange)
                    }
                    if !self.directMode {
                        textInput.selectMode(inputMode.rawValue)
                        
                        let showInputModePanel = UserDefaults.app.bool(forKey: UserDefaultsKeys.showInputModePanel)
                        if showInputModePanel {
                            displayInputModePanel.send(inputMode)
                        }
                    }
                }
            }
        }.store(in: &cancellables)
        stateMachine.candidateEvent.sink { [weak self] candidates in
            guard let self else { return }
            let showAnnotation = UserDefaults.app.bool(forKey: UserDefaultsKeys.showAnnotation)
            Global.candidatesPanel.setShowAnnotationPopover(showAnnotation)
            if let candidates {
                // 下線のスタイルがthickのときに被らないように1ピクセル下に余白を設ける
                var cursorPosition = cursorPosition(for: textInput).offsetBy(dx: 0, dy: -1)
                cursorPosition.size.height += 1
                Global.candidatesPanel.setCursorPosition(cursorPosition)

                if let page = candidates.page {
                    let currentCandidates: CurrentCandidates = .panel(words: page.words,
                                                                      currentPage: page.current,
                                                                      totalPageCount: page.total)
                    Global.candidatesPanel.setCandidates(currentCandidates, selected: candidates.selected)
                    Global.candidatesPanel.show(windowLevel: windowLevel(for: textInput))
                } else {
                    if candidates.selected.annotations.isEmpty || !showAnnotation {
                        Global.candidatesPanel.orderOut(nil)
                    } else {
                        Global.candidatesPanel.show(windowLevel: windowLevel(for: textInput))
                    }
                    Global.candidatesPanel.setCandidates(.inline, selected: candidates.selected)
                }
            } else {
                // 変換→キャンセル→再変換しても注釈が表示されなくならないように状態を変えておく
                self.selectedWord.send(nil)
                Global.candidatesPanel.orderOut(nil)
            }
        }.store(in: &cancellables)
        Global.candidatesPanel.viewModel.$selected.compactMap { $0 }.sink { [weak self] selected in
            self?.stateMachine.didSelectCandidate(selected, textInput: textInput)
            // TODO: バックグラウンドで引いて表示のときだけフォアグラウンドで処理をさせたい
            // TODO: 一度引いた単語を二度引かないようにしたい
            self?.selectedWord.send(selected.word)
        }.store(in: &cancellables)
        Global.candidatesPanel.viewModel.$doubleSelected.compactMap { $0 }.sink { [weak self] doubleSelected in
            self?.stateMachine.didDoubleSelectCandidate(doubleSelected, textInput: textInput)
        }.store(in: &cancellables)
        selectedWord.removeDuplicates().compactMap({ $0 }).sink { [weak self] word in
            if UserDefaults.app.bool(forKey: UserDefaultsKeys.showAnnotation) {
                if let self, let systemAnnotation = SystemDict.lookup(word, for: Global.systemDict), !systemAnnotation.isEmpty {
                    Global.candidatesPanel.setSystemAnnotation(systemAnnotation, for: word)
                    Global.candidatesPanel.show(windowLevel: windowLevel(for: textInput))
                }
            }
        }.store(in: &cancellables)
        Global.directModeBundleIdentifiers.sink { [weak self] bundleIdentifiers in
            if let bundleIdentifier = self?.targetApp.bundleIdentifier {
                self?.directMode = bundleIdentifiers.contains(bundleIdentifier)
            }
        }.store(in: &cancellables)
        Global.insertBlankStringBundleIdentifiers.sink { [weak self] bundleIdentifiers in
            if let bundleIdentifier = self?.targetApp.bundleIdentifier {
                self?.insertBlankString = bundleIdentifiers.contains(bundleIdentifier)
            }
        }.store(in: &cancellables)
        Global.treatFirstCharacterAsMarkedTextBundleIdentifiers.sink { [weak self] bundleIdentifiers in
            if let self, let bundleIdentifier = self.targetApp.bundleIdentifier {
                let enabled = bundleIdentifiers.contains(bundleIdentifier)
                self.treatFirstCharacterAsMarkedText = enabled
                self.stateMachine.enableMarkedTextWorkaround = enabled
            }
        }.store(in: &cancellables)
        Global.showMarkerWhenEmptyBundleIdentifiers.sink { [weak self] bundleIdentifiers in
            if let bundleIdentifier = self?.targetApp.bundleIdentifier {
                self?.showMarkerWhenEmpty = bundleIdentifiers.contains(bundleIdentifier)
            }
        }.store(in: &cancellables)
        // 読みが更新・補完されたときの処理。
        // 補完候補の検索(MainActor外で実行する@concurrentな関数)と
        // 補完候補パネルへの反映はCompletionPresenterに委譲している。
        completionPresenter = CompletionPresenter(panel: Global.completionPanel)
        stateMachine.yomiEvent
            .sink { [weak self] event in
                guard let self else { return }
                self.completionPresenter.handle(
                    event,
                    state: self.stateMachine,
                    cursorPosition: { [weak self] in self?.cursorPosition(for: textInput) ?? .zero },
                    windowLevel: { [weak self] in self?.windowLevel(for: textInput) ?? .floating })
            }
            .store(in: &cancellables)
        // Safariでアドレスバーに移動するときなど、処理が固まることがあるので非同期で実行する
        // https://github.com/mtgto/macSKK/issues/336
        displayInputModePanel
            .merge(with: inputModeChangedOutside)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inputMode in
                if let self {
                    Global.inputModePanel.show(at: cursorPosition(for: textInput).origin,
                                               mode: inputMode,
                                               privateMode: Global.privateMode.value,
                                               windowLevel: windowLevel(for: textInput))
                }
            }.store(in: &cancellables)

        stateMachine.inlineCandidateCount = UserDefaults.app.integer(forKey: UserDefaultsKeys.inlineCandidateCount)
        NotificationCenter.default.publisher(for: notificationNameInlineCandidateCount)
            .sink { [weak self] notification in
                if let inlineCandidateCount = notification.object as? Int, inlineCandidateCount >= 0 {
                    self?.stateMachine.inlineCandidateCount = inlineCandidateCount
                }
            }.store(in: &cancellables)
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // event・sender(非Sendable)は同期的に使うだけなので退避して渡す。
        nonisolated(unsafe) let event = event
        nonisolated(unsafe) let sender = sender
        return mainSync { this in
            // 文字ビューアで入力した場合など、eventがnilの場合がありえる
            guard let event else {
                return false
            }
            return this.handle(event: event, textInput: sender as? any IMKTextInput)
        }
    }

    /// キーイベントを処理して、入力を横取りしたかどうかを返す。
    /// EXP: 初期化時に受け取ったクライアント
    private var expInitClient: (any IMKTextInput)?

    private func handle(event: NSEvent, textInput: (any IMKTextInput)?) -> Bool {
        if let textInput, let initClient = expInitClient {
            let current = self.client() as AnyObject?
            logger.log("EXP client: sender=\(String(describing: ObjectIdentifier(textInput as AnyObject)), privacy: .public) \(String(describing: type(of: textInput as AnyObject)), privacy: .public) init=\(String(describing: ObjectIdentifier(initClient as AnyObject)), privacy: .public) client()=\(String(describing: current.map { ObjectIdentifier($0) }), privacy: .public) 同一=\((textInput as AnyObject) === (initClient as AnyObject), privacy: .public)")
            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            // ⌃⌥U: 本物の確定アンドゥを⌃⌥のキーで動かす
            if mods == [.control, .option], key == "u" {
                logger.log("EXP ⌃⌥U: 変換候補パネルなしで確定アンドゥを実行")
                stateMachine.expSkipCandidatePanel = true
                defer { stateMachine.expSkipCandidatePanel = false }
                return stateMachine.handle(Action(keyBind: .kakuteiUndo, event: event, textInput: textInput))
            }
            // ⌃⌥Q: Jのあと、確定アンドゥの判定と同じ読み直しをする
            if mods == [.control, .option], key == "q" {
                let caret = textInput.selectedRange().location
                _ = AdaptorExperiment.variant("j", textInput: textInput)
                let a = textInput.attributedSubstring(from: NSRange(location: caret - 4, length: 3))?.string ?? "nil"
                let b = textInput.attributedSubstring(from: NSRange(location: caret, length: 3))?.string ?? "nil"
                logger.log("EXP ⌃⌥Q: 読み直し 置きたい位置=\(a, privacy: .public) キャレット位置=\(b, privacy: .public)")
                return true
            }
            // ⌃⌥X: Jのあと、変換候補パネルの位置決めと同じ問い合わせをする
            if mods == [.control, .option], key == "x" {
                _ = AdaptorExperiment.variant("j", textInput: textInput)
                var rect: NSRect = .zero
                _ = textInput.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
                let level = textInput.windowLevel()
                logger.log("EXP ⌃⌥X: rect=\(String(describing: rect), privacy: .public) level=\(level, privacy: .public)")
                return true
            }
            // ⌃⇧J: Jと同じ呼び出しを⌃⇧のキーで動かす
            if mods == [.control, .shift], key == "j" {
                logger.log("EXP ⌃⇧J")
                return AdaptorExperiment.variant("j", textInput: textInput)
            }
            // ⌃⌥L: Jと同じ呼び出しを初期化時のクライアントで行う
            if event.modifierFlags.intersection([.control, .option, .command]) == [.control, .option],
               event.charactersIgnoringModifiers?.lowercased() == "l" {
                return AdaptorExperiment.variant("j", textInput: initClient, readFrom: textInput)
            }
        }
        if AdaptorExperiment.handle(event: event, textInput: textInput) {
            return true
        }
        let keyBind = Global.keyBinding.action(event: event, inputMode: stateMachine.state.inputMode, inputMethod: stateMachine.state.inputMethod)
        if directMode {
            if let keyBind, keyBind == .kana || keyBind == .eisu {
                // 英数・かなキーは握り潰さないとエディタによって空白が入ってしまう
                return true
            }
            return false
        }
        if keyBind == nil && event.charactersIgnoringModifiers == nil {
            return stateMachine.handleUnhandledEvent(event)
        }

        return stateMachine.handle(Action(keyBind: keyBind, event: event, textInput: textInput))
    }

    // NSMenuはSendableでないためmainSyncの戻り値として直接返せない。
    // メインスレッドで生成したメニューをnonisolated(unsafe)なローカルに受け渡して返す。
    nonisolated override func menu() -> NSMenu! {
        nonisolated(unsafe) var result: NSMenu?
        mainSync {
            result = $0.buildMenu()
        }
        return result
    }

    private func buildMenu() -> NSMenu {
        let preferenceMenu = NSMenu()
        preferenceMenu.addItem(
            withTitle: String(localized: "MenuItemPreference", comment: "Preferences…"),
            action: #selector(showSettings), keyEquivalent: "")
        if Global.dictionary.hasUnsavedChanges {
            preferenceMenu.addItem(
                withTitle: String(localized: "MenuItemSaveDict", comment: "Save User Dictionary"),
                action: #selector(saveDict), keyEquivalent: "")
        }
        if !Global.privateMode.value && !Global.dictionary.recentRegisteredCandidates.isEmpty {
            preferenceMenu.addItem(.separator())
            let recentRegisteredCandidatesHeaderItem = NSMenuItem(title: String(localized: "MenuItemUndoRecentRegisteredCandidate"),
                                                                   action: nil,
                                                                   keyEquivalent: "")
            recentRegisteredCandidatesHeaderItem.isEnabled = false
            preferenceMenu.addItem(recentRegisteredCandidatesHeaderItem)
            for (index, entry) in Global.dictionary.recentRegisteredCandidates.enumerated() {
                let item = NSMenuItem(title: entry.menuTitle,
                                      action: #selector(deleteRecentRegisteredCandidate),
                                      keyEquivalent: "")
                item.tag = index
                preferenceMenu.addItem(item)
            }
            preferenceMenu.addItem(.separator())
        }
        let privateModeItem = NSMenuItem(title: String(localized: "MenuItemPrivateMode", comment: "Private mode"),
                                         action: #selector(togglePrivateMode),
                                         keyEquivalent: "")
        privateModeItem.state = Global.privateMode.value ? .on : .off
        preferenceMenu.addItem(privateModeItem)
        if targetApp.bundleIdentifier != nil {
            let directModeItem = NSMenuItem(title: String(format: String(localized: "MenuItemDirectInput", comment: "\"%@\"では直接入力"), targetApp.localizedName ?? "?"),
                                            action: #selector(toggleDirectMode),
                                            keyEquivalent: "")
            directModeItem.state = directMode ? .on : .off
            preferenceMenu.addItem(directModeItem)
            // NOTE: IMKInputControllerのmenuではsubmenuを指定してもOSに無視されるみたい
            let insertBlankStringMenuItem = NSMenuItem(title: String(localized: "MenuItemInsertBlankString", comment: "空文字挿入 (互換性)"), action: #selector(toggleInsertBlankString), keyEquivalent: "")
            insertBlankStringMenuItem.state = insertBlankString ? .on : .off
            preferenceMenu.addItem(insertBlankStringMenuItem)
            let treatFirstCharacterAsMarkedTextMenuItem = NSMenuItem(title: String(localized: "MenuItemTreadFirstCharacterAsMarkedText"), action: #selector(toggleTreatFirstCharacterAsMarkedText), keyEquivalent: "")
            treatFirstCharacterAsMarkedTextMenuItem.state = treatFirstCharacterAsMarkedText ? .on : .off
            preferenceMenu.addItem(treatFirstCharacterAsMarkedTextMenuItem)
            let showMarkerWhenEmptyMenuItem = NSMenuItem(title: String(localized: "MenuItemShowMarkerWhenEmpty"), action: #selector(toggleShowMarkerWhenEmpty), keyEquivalent: "")
            showMarkerWhenEmptyMenuItem.state = showMarkerWhenEmpty ? .on : .off
            preferenceMenu.addItem(showMarkerWhenEmptyMenuItem)
        }
        let skkservMenuItem = NSMenuItem(
            title: String(localized: "MenuItemSKKServ", comment: "SKKServ"),
            action: #selector(toggleSKKServ),
            keyEquivalent: "")
        skkservMenuItem.state = Global.skkservDict != nil ? .on : .off
        preferenceMenu.addItem(skkservMenuItem)
        #if DEBUG
        // デバッグ用
        preferenceMenu.addItem(
            withTitle: "Show Panel",
            action: #selector(showPanel), keyEquivalent: "")
        #endif
        return preferenceMenu
    }

    // MARK: - IMKStateSetting
    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        // 他の入力に切り替わるときには入力候補や補完候補は消す + 現在表示中の候補を確定させる
        nonisolated(unsafe) let sender = sender
        mainSync { _ in
            Global.candidatesPanel.orderOut(sender)
            Global.completionPanel.orderOut(sender)
        }
        super.deactivateServer(sender)
    }

    /// クライアントが入力中状態を即座に確定してほしいときに呼ばれる
    nonisolated override func commitComposition(_ sender: Any!) {
        // 現在未確定の入力を強制的に確定させて状態を入力前の状態にする
        mainSync {
            $0.stateMachine.commitComposition()
        }
    }

    nonisolated override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        nonisolated(unsafe) let value = value
        nonisolated(unsafe) let sender = sender
        mainSync {
            $0.handleSetValue(value, client: sender)
        }
    }

    private func handleSetValue(_ value: Any!, client sender: Any!) {
        guard let value = value as? String else { return }
        guard let inputMode = InputMode(rawValue: value) else { return }
        logger.debug("入力モードが変更されました \(inputMode.rawValue)")
        stateMachine.setMode(inputMode)
        guard let textInput = sender as? any IMKTextInput else {
            logger.warning("setValueの引数clientがIMKTextInputではありません")
            return
        }
        
        let showInputModePanel = UserDefaults.app.bool(forKey: UserDefaultsKeys.showInputModePanel)
        if showInputModePanel && !directMode {
            // Safariでアドレスバーに移動するときなど、処理が固まることがあるので非同期で実行する
            // ただしIMKTextInputへのアクセスはsetValue内で同期で行う必要がある
            displayInputModePanel.send(inputMode)
        }
        // キー配列を設定する
        setCustomInputSource(textInput: textInput)
    }

    @objc func showSettings() {
        if #available(macOS 14, *) {
            NotificationCenter.default.post(name: notificationNameOpenSettings, object: nil)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc func saveDict() {
        Global.dictionary.save()
    }

    @objc func deleteRecentRegisteredCandidate(_ sender: Any?) {
        // IMKInputControllerでNSMenuItemにアクセスするにはkIMKCommandMenuItemNameを使う必要がある
        if let sender = sender as? [String: Any],
           let menuItem = sender[kIMKCommandMenuItemName] as? NSMenuItem {
            let index = menuItem.tag
            guard index < Global.dictionary.recentRegisteredCandidates.count else {
                logger.error("直近登録エントリの削除メニューが選択されましたが、削除対象のindex \(index) が範囲外です")
                return
            }

            let entry = Global.dictionary.recentRegisteredCandidates[index]
            if !Global.dictionary.delete(yomi: entry.yomi, word: entry.word) {
                logger.error("直近登録エントリ \(entry.yomi, privacy: .public) \(entry.word.word, privacy: .public) を削除できませんでした")
            }
        }
    }

    @objc func togglePrivateMode() {
        Global.privateMode.send(!Global.privateMode.value)
    }

    /// 現在最前面にあるアプリからの入力をハンドルしないかどうかを切り替える
    @objc func toggleDirectMode() {
        if let bundleIdentifier = targetApp.bundleIdentifier {
            NotificationCenter.default.post(name: notificationNameToggleDirectMode, object: bundleIdentifier)
        }
    }

    /// 現在最前面にあるアプリで、ワークアラウンドの空文字挿入の有効無効を切り換える
    @objc func toggleInsertBlankString() {
        if let bundleIdentifier = targetApp.bundleIdentifier {
            NotificationCenter.default.post(name: notificationNameToggleInsertBlankString, object: bundleIdentifier)
        }
    }

    /// 現在最前面にあるアプリで、ワークアラウンドの1文字目を常に未確定扱いするかの有効無効を切り替える
    @objc func toggleTreatFirstCharacterAsMarkedText() {
        if let bundleIdentifier = targetApp.bundleIdentifier {
            NotificationCenter.default.post(name: notificationNameToggleTreatFirstCharacterAsMarkedText, object: bundleIdentifier)
        }
    }

    /// 現在最前面にあるアプリで、ワークアラウンドの空のときには▽▼を表示するかの有効無効を切り替える
    @objc func toggleShowMarkerWhenEmpty() {
        if let bundleIdentifier = targetApp.bundleIdentifier {
            NotificationCenter.default.post(name: notificationNameToggleShowMarkerWhenEmpty, object: bundleIdentifier)
        }
    }

    /// SKKServの有効無効を切り替える
    @objc func toggleSKKServ() {
        NotificationCenter.default.post(name: notificationNameToggleSKKServ, object: nil)
    }

    #if DEBUG
    @objc func showPanel() {
        let point = NSPoint(x: 100, y: 500)
        Global.inputModePanel.show(at: point, mode: .hiragana, privateMode: Global.privateMode.value, windowLevel: .floating)
    }
    #endif

    // MARK: -
    private func isPrintable(_ text: String) -> Bool {
        let printable = [CharacterSet.alphanumerics, CharacterSet.symbols, CharacterSet.punctuationCharacters]
            .reduce(CharacterSet()) { $0.union($1) }
        return !text.unicodeScalars.contains { !printable.contains($0) }
    }

    // キー配列を設定する
    private func setCustomInputSource(textInput: any IMKTextInput) {
        if let inputSourceID = UserDefaults.app.string(forKey: UserDefaultsKeys.selectedInputSource) {
            logger.info("InputSourceIDを \(inputSourceID, privacy: .public) に設定します")
            textInput.overrideKeyboard(withKeyboardNamed: inputSourceID)
        } else {
            logger.info("InputSourceIDは選択されていません")
        }
    }

    /// 現在のカーソル位置。正常に取得できない場合はNSRect.zeroになっている。
    private func cursorPosition(for textInput: any IMKTextInput) -> NSRect {
        // 左下座標基準でwidth=1, height=(通常だとフォントサイズ)のNSRect
        // TODO: 単語登録中など、現在のカーソル位置が0ではないときはそれに合わせて座標を取得したい
        // forCharacterIndexを0以外で取得しようとすると取得できないことがあるためひとまず断念
        var cursorPosition: NSRect = .zero
        _ = textInput.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorPosition)
        return cursorPosition
    }

    /// 変換候補パネルや補完候補などを表示するべきウィンドウレベル。
    private func windowLevel(for textInput: any IMKTextInput) -> NSWindow.Level {
        NSWindow.Level(rawValue: Int(textInput.windowLevel() + 1))
    }
}

// MARK: - EXP: 標準IMEが使うIMKTextDocumentTextInputAdaptorがクライアントに何を呼ぶかを記録する (pushしない)

private func expRange(_ r: NSRange) -> String {
    r.location == NSNotFound ? "(NotFound,\(r.length))" : "(\(r.location),\(r.length))"
}

private func expString(_ s: Any?) -> String {
    if let a = s as? NSAttributedString { return "\"\(a.string)\"" }
    if let s = s as? String { return "\"\(s)\"" }
    return String(describing: s)
}

/// 受けた呼び出しをすべてログに出してから本物のクライアントに渡す
final class ExpLoggingTextInput: NSObject, IMKTextInput {
    let base: any IMKTextInput
    init(base: any IMKTextInput) { self.base = base }
    private func log(_ message: String) { logger.log("EXP adaptor→client: \(message, privacy: .public)") }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        log("insertText(\(expString(string)), replacementRange: \(expRange(replacementRange)))")
        base.insertText(string, replacementRange: replacementRange)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        log("setMarkedText(\(expString(string)), selectionRange: \(expRange(selectionRange)), replacementRange: \(expRange(replacementRange)))")
        base.setMarkedText(string, selectionRange: selectionRange, replacementRange: replacementRange)
    }
    func selectedRange() -> NSRange { let r = base.selectedRange(); log("selectedRange() -> \(expRange(r))"); return r }
    func markedRange() -> NSRange { let r = base.markedRange(); log("markedRange() -> \(expRange(r))"); return r }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        let r = base.attributedSubstring(from: range); log("attributedSubstring(\(expRange(range))) -> \(expString(r))"); return r
    }
    func length() -> Int { let r = base.length(); log("length() -> \(r)"); return r }
    func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int {
        log("characterIndex(for:)"); return base.characterIndex(for: point, tracking: tracking, inMarkedRange: inMarkedRange)
    }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        log("attributes(forCharacterIndex: \(index))"); return base.attributes(forCharacterIndex: index, lineHeightRectangle: lineRect)
    }
    func validAttributesForMarkedText() -> [Any]! { log("validAttributesForMarkedText()"); return base.validAttributesForMarkedText() }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) { log("overrideKeyboard"); base.overrideKeyboard(withKeyboardNamed: keyboardUniqueName) }
    func selectMode(_ modeIdentifier: String!) { log("selectMode(\(modeIdentifier ?? "nil"))"); base.selectMode(modeIdentifier) }
    func supportsUnicode() -> Bool { let r = base.supportsUnicode(); log("supportsUnicode() -> \(r)"); return r }
    func bundleIdentifier() -> String! { let r = base.bundleIdentifier(); log("bundleIdentifier() -> \(r ?? "nil")"); return r }
    func windowLevel() -> CGWindowLevel { log("windowLevel()"); return base.windowLevel() }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool {
        let r = base.supportsProperty(property)
        let tag = String(bytes: withUnsafeBytes(of: property.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(property)"
        log("supportsProperty('\(tag)') -> \(r)"); return r
    }
    func uniqueClientIdentifierString() -> String! { log("uniqueClientIdentifierString()"); return base.uniqueClientIdentifierString() }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        let r = base.string(from: range, actualRange: actualRange); log("string(from: \(expRange(range))) -> \(expString(r))"); return r
    }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect {
        log("firstRect(\(expRange(aRange)))"); return base.firstRect(forCharacterRange: aRange, actualRange: actualRange)
    }
    override func responds(to aSelector: Selector!) -> Bool {
        let r = super.responds(to: aSelector)
        if !r { log("respondsToSelector(\(NSStringFromSelector(aSelector))) -> false") }
        return r
    }
}

enum AdaptorExperiment {
    /// ⌃⌥R: キャレットの前の2文字をrecomposeする。⌃⌥M: キャレットを2文字戻す。
    @MainActor static func handle(event: NSEvent, textInput: (any IMKTextInput)?) -> Bool {
        guard let textInput, event.modifierFlags.intersection([.control, .option, .command]) == [.control, .option],
              let ch = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        if ["a", "s", "d", "f", "g", "h", "j", "k"].contains(ch) {
            return variant(ch, textInput: textInput)
        }
        guard ch == "r" else {
            return false
        }
        guard let cls = NSClassFromString("IMKTextDocumentTextInputAdaptor") as? NSObject.Type else {
            logger.log("EXP adaptor: クラスが見つからない")
            return true
        }
        let wrapper = ExpLoggingTextInput(base: textInput)
        let allocated = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>
        let initSel = NSSelectorFromString("initWithTextInputToAdapt:")
        let doc = unsafeBitCast(allocated.method(for: initSel), to: InitFn.self)(allocated, initSel, wrapper).takeRetainedValue()
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        func call(_ name: String) {
            let sel = NSSelectorFromString(name)
            logger.log("EXP adaptor: [\(name, privacy: .public)] 開始")
            unsafeBitCast(doc.method(for: sel), to: VoidFn.self)(doc, sel)
        }
        logger.log("EXP adaptor: ===== \(ch, privacy: .public) 開始 bundle=\(textInput.bundleIdentifier() ?? "nil", privacy: .public)")
        call("beginEdit")
        if ch == "r" {
            typealias RecomposeFn = @convention(c) (AnyObject, Selector, UInt, Int) -> Unmanaged<AnyObject>?
            let sel = NSSelectorFromString("recomposeCharacters:before:")
            logger.log("EXP adaptor: [recomposeCharacters:2 before:0] 開始")
            let result = unsafeBitCast(doc.method(for: sel), to: RecomposeFn.self)(doc, sel, 2, 0)?.takeUnretainedValue()
            logger.log("EXP adaptor: recompose -> \(String(describing: result), privacy: .public)")
        } else {
            typealias MoveFn = @convention(c) (AnyObject, Selector, Int) -> UInt
            let sel = NSSelectorFromString("moveCursorByCharacterCount:")
            logger.log("EXP adaptor: [moveCursorByCharacterCount:-2] 開始")
            let result = unsafeBitCast(doc.method(for: sel), to: MoveFn.self)(doc, sel, -2)
            logger.log("EXP adaptor: move -> \(result, privacy: .public)")
        }
        call("endEdit")
        call("commitChanges")
        logger.log("EXP adaptor: ===== 終了")
        return true
    }

    /// キャレットの前の2文字を、条件を1つずつ変えたsetMarkedTextで未確定文字列にする
    /// - A: 素の文字列・同じ内容・selectionRangeあり (標準IMEの部品と同じ)
    /// - S: 素の文字列・同じ内容・selectionRangeがNotFound
    /// - D: 素の文字列・▼付き・selectionRangeあり
    /// - F: 属性付き・▼付き・selectionRangeあり
    /// - G: 属性付き・▼付き・selectionRangeがNotFound (いまの確定アンドゥと同じ)
    @MainActor static func variant(_ ch: String, textInput: any IMKTextInput, readFrom: (any IMKTextInput)? = nil) -> Bool {
        let reader = readFrom ?? textInput
        let caret = reader.selectedRange()
        guard caret.location != NSNotFound, caret.location >= 2 else {
            logger.log("EXP variant \(ch, privacy: .public): キャレットが不正 \(expRange(caret), privacy: .public)")
            return true
        }
        // H・J・K はキャレットから離れた範囲 (「各停する|」の「各停」) を対象にする
        let far = ["h", "j", "k"].contains(ch)
        guard !far || caret.location >= 4 else {
            logger.log("EXP variant \(ch, privacy: .public): キャレットが不正 \(expRange(caret), privacy: .public)")
            return true
        }
        let range = far ? NSRange(location: caret.location - 4, length: 2) : NSRange(location: caret.location - 2, length: 2)
        let t = reader.attributedSubstring(from: range)?.string ?? "??"
        let notFound = NSRange(location: NSNotFound, length: NSNotFound)
        let marked = MarkedText([.markerSelect, .emphasized(t)])
        let attributed = NSAttributedString(marked.attributedString(true))
        let string: Any
        let selection: NSRange
        switch ch {
        case "a": string = t as NSString; selection = NSRange(location: 2, length: 0)
        case "s": string = t as NSString; selection = notFound
        case "d": string = ("▼" + t) as NSString; selection = NSRange(location: 3, length: 0)
        case "f": string = attributed; selection = NSRange(location: 3, length: 0)
        // H: Aと同じ渡し方で離れた範囲。J: Gと同じ渡し方で離れた範囲。
        case "h": string = t as NSString; selection = NSRange(location: 2, length: 0)
        case "j": string = attributed; selection = notFound
        // K: 離れた範囲の代わりに、その範囲からキャレットまでをまとめて置き換える (「▼各停」+「する」)
        case "k":
            let rest = textInput.attributedSubstring(from: NSRange(location: caret.location - 2, length: 2))?.string ?? "??"
            let m = MarkedText([.markerSelect, .emphasized(t), .cursor, .plain(rest)])
            logger.log("EXP variant k: bundle=\(textInput.bundleIdentifier() ?? "nil", privacy: .public) setMarkedText(\(NSAttributedString(m.attributedString(true)).string, privacy: .public), selectionRange: \(expRange(m.cursorRange(true) ?? notFound), privacy: .public), replacementRange: \(expRange(NSRange(location: range.location, length: 4)), privacy: .public))")
            textInput.setMarkedText(NSAttributedString(m.attributedString(true)), selectionRange: m.cursorRange(true) ?? notFound,
                                    replacementRange: NSRange(location: range.location, length: 4))
            return true
        default: string = attributed; selection = notFound
        }
        logger.log("EXP variant \(ch, privacy: .public): bundle=\(textInput.bundleIdentifier() ?? "nil", privacy: .public) setMarkedText(\(expString(string), privacy: .public), selectionRange: \(expRange(selection), privacy: .public), replacementRange: \(expRange(range), privacy: .public))")
        textInput.setMarkedText(string, selectionRange: selection, replacementRange: range)
        return true
    }
}
