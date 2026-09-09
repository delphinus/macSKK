// SPDX-FileCopyrightText: 2022 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import Combine
import InputMethodKit

/// ActionによってIMEに関する状態が変更するイベントの列挙
enum InputMethodEvent: Equatable {
    /// 確定文字列
    case fixedText(String)
    /// 下線付きの未確定文字列
    ///
    /// 登録モード時は "[登録：あああ]ほげ" のように長くなる
    case markedText(MarkedText)
    /// すでにクライアントに送った確定文字列を別の確定文字列で置き換える。確定のやり直しで使う。
    ///
    /// replacementRangeはクライアントのドキュメント先頭からの範囲。
    /// クライアントが範囲指定に対応していない場合は置き換わらずに追記されるため、
    /// 送ったあとに置き換えられたかを確認すること。
    case replaceFixedText(String, replacementRange: NSRange)
    /// qやlなどにより入力モードを変更する
    case modeChanged(InputMode)
}

/// 読み入力部分が変更されたイベント。
enum YomiEvent: Equatable {
    /// Tabにより読み部分が補完されたとき。このイベントが渡されたときは補完候補は検索しなくてよい。
    /// Associated Valueは次の読みの補完候補。次の補完候補がない場合は空文字列。
    case completed(String)
    /// 補完のとき以外。キーボード操作により読み部分が変更されたとき、読み部分が空文字列になったとき。
    /// 補完が有効なら補完候補の検索が行われる。
    case other(String)
}

final class StateMachine {
    private(set) var state: IMEState
    let inputMethodEvent: AnyPublisher<InputMethodEvent, Never>
    private let inputMethodEventSubject = PassthroughSubject<InputMethodEvent, Never>()
    let candidateEvent: AnyPublisher<Candidates?, Never>
    private let candidateEventSubject = PassthroughSubject<Candidates?, Never>()
    /**
     * 現在入力中の未変換の読み部分の文字列が更新されたときに通知される。
     * 補完が行われたときはStateMachineのプロパティcompletionがCompletion.yomiのときだけ通知される。
     *
     * 通知される文字列は全角ひらがな(Abbrev以外)もしくは英数(Abbrev)。
     * 送り仮名がローマ字で一文字でも入力されたときは新しく通知はされない。
     * 入力中の文字列のカーソルを左右に移動した場合はカーソルの左側までが更新された文字列として通知される。
     */
    let yomiEvent: AnyPublisher<YomiEvent, Never>
    private let yomiEventSubject = PassthroughSubject<YomiEvent, Never>()
    /// 読みの一部と補完結果(読み)のペア
    var completion: Completion? = nil {
        didSet {
            completionSetAt = completion == nil ? nil : Date()
        }
    }
    /// completionがセットされた日時。一定時間経過後に確定キーが押されたら確定とみなすために使用する
    var completionSetAt: Date? = nil

    /// 変換候補パネルを表示するまで表示する変換候補の数
    var inlineCandidateCount: Int
    /// 1文字で確定するローマ字やq/lなどのモード変更などで未確定文字列を一度表示するワークグラウンドが有効かどうか
    /// xterm.jsを利用しているVSCodeのターミナルやHyperなどaiueoで直接入力されてしまう環境向け
    var enableMarkedTextWorkaround: Bool
    /// 直前に変換候補選択から確定した内容。確定のやり直し (``KeyBinding/Action/fixNextCandidate``) で使う。
    /// 確定以外の文字列をクライアントに送ったときはnilに戻す。
    private var lastFix: LastFix?

    /// 直前に変換候補選択から確定した内容
    private struct LastFix {
        /// 確定したときの変換候補選択状態
        let selecting: SelectingState
        /// クライアント上で確定文字列が始まる位置。確定した時点では不明なのでnil
        let location: Int?
        /// クライアントに送った確定文字列
        let text: String
        /// 確定のやり直しで置き換える前にクライアントにあった文字列。
        /// クライアントによっては置き換えた直後の読み取りが古い文字列を返すため、その判定に使う
        let previousText: String?
        /// 確定のやり直しの最中かどうか。
        /// 変換候補パネルを表示していて、選択中の変換候補をまだユーザー辞書に登録していない状態。
        var redoing: Bool = false
    }

    init(initialState: IMEState = IMEState(), inlineCandidateCount: Int = 3, enableMarkedTextWorkaround: Bool = false) {
        state = initialState
        inputMethodEvent = inputMethodEventSubject.eraseToAnyPublisher()
        candidateEvent = candidateEventSubject.removeDuplicates().eraseToAnyPublisher()
        yomiEvent = yomiEventSubject.removeDuplicates().eraseToAnyPublisher()
        self.inlineCandidateCount = inlineCandidateCount
        self.enableMarkedTextWorkaround = enableMarkedTextWorkaround
    }

    /// `Action`をハンドルした場合には`true`、しなかった場合は`false`を返す
    @MainActor func handle(_ action: Action) -> Bool {
        if action.keyBind != .fixNextCandidate && action.keyBind != .fixPrevCandidate {
            // 確定のやり直し中は変換候補パネルを表示しているので、変換候補選択と同じ操作も受け付ける。
            // どちらでもないキーが押されたらやり直しは終わったものとみなす
            if handleRedoingFixedText(action) {
                return true
            }
            finishRedoFixedText()
        }
        switch state.inputMethod {
        case .normal:
            return handleNormal(action, specialState: state.specialState)
        case .composing(let composing):
            return handleComposing(action, composing: composing, specialState: state.specialState)
        case .selecting(let selecting):
            return handleSelecting(action, selecting: selecting, specialState: state.specialState)
        }
    }

    /// macSKKで取り扱わないキーイベントを処理するかどうかを返す
    @MainActor func handleUnhandledEvent(_ event: NSEvent) -> Bool {
        // 確定のやり直しのキーはキーバインドとして解決されるのでここには来ない
        finishRedoFixedText()
        if state.specialState != nil {
            return true
        }
        switch state.inputMethod {
        case .normal:
            return false
        case .composing, .selecting:
            return true
        }
    }

    /**
     * 状態がnormalのときのhandle
     */
    @MainActor func handleNormal(_ action: Action, specialState: SpecialState?) -> Bool {
        switch action.keyBind {
        case .hiragana, .kana:
            if case .unregister = specialState {
                return true
            } else {
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                if specialState != nil {
                    updateMarkedText()
                } else if enableMarkedTextWorkaround && action.keyBind != .kana {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[かな]")))
                    updateMarkedText()
                }
                return true
            }
        case .japanese:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                // 見出し語入力へ遷移する
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                updateMarkedText()
                return true
            case .eisu, .direct:
                break
            }
        case .toggleKana:
            switch state.inputMode {
            case .hiragana:
                state.inputMode = .katakana
                inputMethodEventSubject.send(.modeChanged(.katakana))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                } else if enableMarkedTextWorkaround {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[カナ]")))
                    updateMarkedText()
                }
                return true
            case .katakana, .hankaku:
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                } else if enableMarkedTextWorkaround {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[かな]")))
                    updateMarkedText()
                }
                return true
            case .eisu, .direct:
                break
            }
        case .hankakuKana:
            switch state.inputMode {
            case .hiragana, .katakana:
                state.inputMode = .hankaku
                inputMethodEventSubject.send(.modeChanged(.hankaku))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                }
                return true
            case .hankaku:
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                }
                return true
            default:
                break
            }
        case .direct:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                state.inputMode = .direct
                inputMethodEventSubject.send(.modeChanged(.direct))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                } else if enableMarkedTextWorkaround {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[英数]")))
                    updateMarkedText()
                }
                return true
            case .eisu, .direct:
                break
            }
        case .toggleDirect:
            // 登録解除確認中はyes/noを入力する場面なのでモードを変更しない
            if case .unregister = specialState {
                return true
            }
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku, .eisu:
                state.inputMode = .direct
                inputMethodEventSubject.send(.modeChanged(.direct))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                } else if enableMarkedTextWorkaround {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[英数]")))
                    updateMarkedText()
                }
            case .direct:
                // 切り替え前のモードは記憶せず常にひらがなに戻す (Windowsのかなキーと同じ挙動)
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                } else if enableMarkedTextWorkaround {
                    // 確定文字を未確定文字列として入力するワークアラウンド
                    state.inputMethod = .composing(
                        ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: "", displayText: "[かな]")))
                    updateMarkedText()
                }
            }
            return true
        case .zenkaku:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                state.inputMode = .eisu
                inputMethodEventSubject.send(.modeChanged(.eisu))
                if specialState != nil {
                    inputMethodEventSubject.send(.markedText(state.displayText()))
                }
                return true
            case .eisu, .direct:
                break
            }
        case .abbrev:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: "", prevMode: state.inputMode))
                state.inputMode = .direct
                inputMethodEventSubject.send(.modeChanged(.direct))
                inputMethodEventSubject.send(.markedText(state.displayText()))
                return true
            case .eisu, .direct:
                break
            }
        case .directAbbrev:
            if state.inputMode == .direct {
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: "", prevMode: state.inputMode))
                state.inputMode = .direct
                inputMethodEventSubject.send(.modeChanged(.direct))
                inputMethodEventSubject.send(.markedText(state.displayText()))
                return true
            }
            break
        case .enter:
            if let specialState {
                if case .register(let registerState, let prev) = specialState {
                    if registerState.text.isEmpty {
                        state.inputMode = registerState.prev.mode
                        state.inputMethod = .composing(registerState.prev.composing)
                        if let last = prev.last {
                            state.specialState = .register(last, prev: prev.dropLast())
                        } else {
                            state.specialState = nil
                        }
                        updateMarkedText()
                    } else {
                        addWordToUserDict(
                            yomi: registerState.yomi,
                            okuri: registerState.okuri,
                            candidate: Candidate(registerState.text),
                            source: .registering)
                        if let last = prev.last {
                            state.specialState = .register(last, prev: prev.dropLast())
                        } else {
                            state.specialState = nil
                        }
                        if let prevMode = registerState.prev.composing.prevMode {
                            // Abbrevモードの終了時の戻り先が指定されていれば、そちらに戻る
                            if state.inputMode != prevMode {
                                state.inputMode = prevMode
                                inputMethodEventSubject.send(.modeChanged(prevMode))
                            }
                        } else {
                            let prevMode = registerState.prev.mode
                            if state.inputMode != prevMode {
                                state.inputMode = prevMode
                                inputMethodEventSubject.send(.modeChanged(prevMode))
                            }
                        }
                        if let okuri = registerState.okuri {
                            addFixedText(registerState.text + okuri)
                        } else {
                            addFixedText(registerState.text)
                        }
                    }
                    return true
                } else if case .unregister(let unregisterState, let prev) = specialState {
                    if unregisterState.text == "yes" {
                        let selecting = unregisterState.prev.selecting
                        let word = selecting.candidates[selecting.candidateIndex]
                        _ = Global.dictionary.delete(yomi: selecting.yomi, word: Word(word.word, okuri: selecting.okuri))

                        if let prevMode = unregisterState.prev.selecting.prev.composing.prevMode {
                            // Abbrevモードの終了時の戻り先が指定されていれば、そちらに戻る
                            if state.inputMode != prevMode {
                                state.inputMode = prevMode
                                inputMethodEventSubject.send(.modeChanged(prevMode))
                            }
                        } else {
                            let prevMode = unregisterState.prev.mode
                            if state.inputMode != prevMode {
                                state.inputMode = unregisterState.prev.mode
                                inputMethodEventSubject.send(.modeChanged(prevMode))
                            }
                        }
                        state.inputMethod = .normal
                        if let prev {
                            state.specialState = .register(prev.0, prev: prev.1)
                        } else {
                            state.specialState = nil
                        }
                        updateMarkedText()
                    } else {
                        state.inputMode = unregisterState.prev.mode
                        updateCandidates(selecting: unregisterState.prev.selecting)
                        state.inputMethod = .selecting(unregisterState.prev.selecting)
                        if let prev {
                            // 登録状態から登録解除状態に行き、また登録状態に戻る
                            state.specialState = .register(prev.0, prev: prev.1)
                        } else {
                            state.specialState = nil
                        }
                        updateMarkedText()
                    }
                    return true
                }
            }
            return false
        case .backspace:
            if let specialState = state.specialState {
                // 単語登録中に空文字列で前候補キーもしくはバックスペースキーで候補選択に戻る（設定されている場合）
                if Global.backToSelectingFromRegistering,
                    case .register(let registerState, let prevRegisterStates) = specialState,
                    registerState.text.isEmpty
                {
                    backToSelectingFromRegister(registerState: registerState, prevRegisterStates: prevRegisterStates)
                    return true
                }
                state.specialState = specialState.dropLast()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .tab:
            if case .register(let registerState, _) = state.specialState {
                if Global.yomiCompletionByTabInRegistering, registerState.text.isEmpty {
                    state.inputMethod = .composing(registerState.prev.composing)
                    updateMarkedText()
                }
                return true
            }
            return false
        case .stickyShift:
            switch state.inputMode {
            case .hiragana, .katakana, .hankaku:
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                updateMarkedText()
                return true
            case .eisu, .direct:
                break
            }
        case .cancel:
            if let specialState = state.specialState {
                switch specialState {
                case .register(let registerState, let prevRegisterStates):
                    state.inputMode = registerState.prev.mode
                    // 送り仮名がある場合は読みに結合する。例えば `Na I` という入力("な*い")をしてからキャンセルするときは
                    // `Nai` という入力をしたときの状態に戻す。
                    state.inputMethod = .composing(registerState.prev.composing.uniteOkuri())
                    if let prevRegisterState = prevRegisterStates.last {
                        state.specialState = .register(prevRegisterState, prev: prevRegisterStates.dropLast())
                    } else {
                        state.specialState = nil
                    }
                case .unregister(let unregisterState, let prev):
                    state.inputMode = unregisterState.prev.mode
                    updateCandidates(selecting: unregisterState.prev.selecting)
                    state.inputMethod = .selecting(unregisterState.prev.selecting)
                    if let prev {
                        state.specialState = .register(prev.0, prev: prev.1)
                    } else {
                        state.specialState = nil
                    }
                }
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .left:
            if let specialState = state.specialState {
                state.specialState = specialState.moveCursorLeft()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .right:
            if let specialState = state.specialState {
                state.specialState = specialState.moveCursorRight()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .startOfLine:
            if let specialState = state.specialState {
                state.specialState = specialState.moveCursorFirst()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .endOfLine:
            if let specialState = state.specialState {
                state.specialState = specialState.moveCursorLast()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .delete:
            if let specialState = state.specialState {
                state.specialState = specialState.dropForward()
                updateMarkedText()
                return true
            } else {
                return false
            }
        case .down, .up:
            if state.specialState != nil {
                return true
            } else {
                return false
            }
        case .registerPaste:
            if case .register = state.specialState {
                if let text = Pasteboard.getString() {
                    addFixedText(text)
                    return true
                } else {
                    return false
                }
            } else {
                return false
            }
        case .reconvert:
            if let textInput = action.textInput {
                if let substring = textInput.attributedSubstring(from: textInput.selectedRange()) {
                    let word = substring.string
                    // TODO: 言う などのように送り仮名つきであれば "言" で検索する (送り仮名もセットで検索したほうがいい)
                    if let yomi = Global.dictionary.reverseRefer(word) {
                        // TODO: いu などのように送り仮名つきの読みかを確認する
                        state.inputMethod = .composing(
                            ComposingState(isShift: true,
                                           text: yomi.map { String($0) },
                                           romaji: "",
                                           reconvertText: word))
                        updateMarkedText()
                    }
                }
            }
            return true
        case .fixNextCandidate, .fixPrevCandidate:
            if redoFixedText(action: action, diff: action.keyBind == .fixNextCandidate ? 1 : -1) {
                return true
            }
            // 置き換えられない場合の扱いは割り当てられたキーによって変える。
            // デフォルトのCtrl-zのような修飾キー付きのキーはアプリに渡さず、なにもせずに握り潰す。
            // Ctrl-BackspaceやCtrl-uのように、アプリに渡るとターミナルなどで直前の単語や
            // 行が削除されてしまうキーを割り当てられるため
            // (ターミナルによっては握り潰してもターミナル側で処理されてしまう)。
            // Shift-xのような文字キーは通常の文字入力として扱う。
            let modifierFlags = action.event.modifierFlags
            if modifierFlags.contains(.control) || modifierFlags.contains(.command) || modifierFlags.contains(.function) {
                return true
            }
            break
        case .eisu:
            // 何もしない (OSがIMEの切り替えはしてくれる)
            return true
        case .backwardCandidate:
            // 単語登録中に空文字列で前候補キーもしくはバックスペースキーで候補選択に戻る（設定されている場合）
            if Global.backToSelectingFromRegistering,
                case .register(let registerState, let prevRegisterStates) = specialState,
                registerState.text.isEmpty
            {
                backToSelectingFromRegister(registerState: registerState, prevRegisterStates: prevRegisterStates)
                return true
            }
            break
        case .space, .shiftSpace, .unregister, .toggleAndFixKana, .affix, nil:
            break
        }

        // 直接入力時かつ下線が引かれた未確定文字列がないときはなにもしない
        if state.inputMode == .direct && state.specialState == nil {
            return false
        }
        let event = action.event
        guard let input = event.charactersIgnoringModifiers else {
            return false
        }
        // 単語登録中は先頭のスペースを無視する（設定されている場合）
        if input == " ",
           case .register(let registerState, _) = specialState,
           Global.ignoreLeadingSpacesWhenRegistering,
           registerState.text.isEmpty {
            return true
        }
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.function) {
            // 単語登録中や登録解除中はtrueを返してなにもしない
            return state.specialState != nil
        } else {
            return handleNormalPrintable(input: input, action: action, specialState: specialState)
        }
    }

    /**
     * 直前に変換候補選択から確定した文字列を、次 (もしくは前) の変換候補で置き換える。
     *
     * ddskkの確定アンドゥ (skk-undo-kakutei) のように未確定文字列 (▼) の状態に戻すことはできない。
     * macOSの入力メソッドからは確定済み文字列の範囲を指定して未確定文字列を置くことができず、
     * setMarkedTextのreplacementRangeは無視されるため (macOS 26で実測)、
     * 範囲指定が有効なinsertTextで確定済み文字列そのものを置き換えている。
     *
     * 確定した直後 (確定した文字列がキャレットの直前に残っているとき) のみ有効。
     * 続けて押すとさらに次の変換候補に進み、最後まで行くと反対側の端の変換候補に戻る。
     *
     * - Parameter diff: 進める変換候補の数。次の変換候補なら1、前の変換候補なら-1。
     * - Returns: 置き換えた場合はtrue、置き換えなかった場合はfalse。
     */
    @MainActor private func redoFixedText(action: Action, diff: Int) -> Bool {
        // 単語登録中の確定はクライアントに文字列を送っていないので対象外
        guard state.specialState == nil, let lastFix, let textInput = action.textInput else {
            return false
        }
        switch state.inputMode {
        case .hiragana, .katakana, .hankaku:
            break
        case .direct, .eisu:
            return false
        }
        let candidates = lastFix.selecting.candidates
        // 変換候補が一つしかないときは置き換えようがない
        guard candidates.count > 1 else {
            return false
        }
        // 端まで行ったら反対側の端に戻る
        let candidateIndex = (lastFix.selecting.candidateIndex + diff % candidates.count + candidates.count) % candidates.count
        return redoFixedText(candidateIndex: candidateIndex, textInput: textInput)
    }

    /**
     * 直前に変換候補選択から確定した文字列を、`candidateIndex` 番目の変換候補で置き換える。
     *
     * 置き換えた場合はtrue、置き換えなかった場合はfalseを返す。
     */
    @MainActor private func redoFixedText(candidateIndex: Int, textInput: any IMKTextInput) -> Bool {
        guard let lastFix else {
            return false
        }
        let selecting = lastFix.selecting
        guard candidateIndex >= 0 && candidateIndex < selecting.candidates.count else {
            return false
        }
        let fixedLength = (lastFix.text as NSString).length
        let selectedRange = textInput.selectedRange()
        // 選択範囲があるときは再変換 (reconvert) の対象なので確定のやり直しはしない
        guard selectedRange.location != NSNotFound, selectedRange.length == 0 else {
            return false
        }
        // クライアント上で確定文字列が始まる位置。
        // 一度置き換えたあとは自分が書き込んだ位置を使う。
        let location: Int
        if let recorded = lastFix.location {
            location = recorded
        } else {
            guard selectedRange.location >= fixedLength else {
                return false
            }
            location = selectedRange.location - fixedLength
        }
        /// クライアントのlocationからの文字列が指定した文字列で、かつその直後にキャレットがあるかどうか
        func clientHas(_ text: String) -> Bool {
            let length = (text as NSString).length
            guard location + length == selectedRange.location else {
                return false
            }
            return textInput.attributedSubstring(from: NSRange(location: location, length: length))?.string == text
        }
        // 確定した文字列がキャレットの直前に残っているときのみ置き換える。
        // 確定後に他の文字を入力していたりカーソルを移動している場合や、
        // クライアントがselectedRange/attributedSubstringに対応していない場合はここで弾かれる。
        //
        // ただしChromiumベースのアプリは範囲を指定して置き換えたときに周辺テキストのキャッシュを
        // 更新しないため、置き換えたあとも置き換える前の文字列を返すことがある。
        // その場合は自分が書き込んだ内容を信用して続行する。
        if !clientHas(lastFix.text) {
            guard let previousText = lastFix.previousText, clientHas(previousText) else {
                return false
            }
            logger.debug("直前の確定の差し替え: クライアントの読み取りが置き換える前の文字列を返しています")
        }
        let newSelecting = SelectingState(prev: selecting.prev,
                                          yomi: selecting.yomi,
                                          candidates: selecting.candidates,
                                          candidateIndex: candidateIndex,
                                          remain: selecting.remain,
                                          completion: selecting.completion)
        let newText = newSelecting.fixedText(dropLast: false)
        guard !newText.isEmpty else {
            return false
        }
        inputMethodEventSubject.send(.replaceFixedText(newText,
                                                       replacementRange: NSRange(location: location, length: fixedLength)))
        // 範囲指定に対応していないクライアントでは置き換えではなく追記になってしまう。
        // 追記されたぶんは元に戻せないが、検出できたら記録して繰り返さないようにする。
        if textInput.selectedRange().location == location + fixedLength + (newText as NSString).length {
            logger.warning("クライアントが確定済み文字列の置き換えに対応していないため文字列が追記されました")
            finishRedoFixedText()
            self.lastFix = nil
            return true
        }
        // 続けて押したときにさらに変換候補を進められるようにする。
        // 選択した変換候補のユーザー辞書への登録はやり直しが終わるまで遅らせる (finishRedoFixedText)
        self.lastFix = LastFix(selecting: newSelecting,
                               location: location,
                               text: newText,
                               previousText: lastFix.text,
                               redoing: true)
        // 変換候補が多いときにコレと思った変換候補を通り過ぎないよう、
        // やり直し中はインライン表示の設定によらず常に変換候補パネルを表示する
        updateCandidates(selecting: newSelecting, inlineCandidateCount: 0)
        return true
    }

    /**
     * 確定のやり直し中 (変換候補パネルの表示中) の、変換候補選択と同じ操作を処理する。
     *
     * パネルを表示している以上そこに見えている操作は効いてほしいので、
     * 変換候補選択中と同じキーで移動と決定ができるようにする。
     * ここで処理しないキーが押されたときは呼び出し元がやり直しを終了する。
     *
     * Enterは処理しない。変換候補選択中は確定キーだが、やり直し中は文字がすでに確定済みで
     * 確定する対象がなく、握り潰すと確定のやり直しの直後に改行や送信ができなくなるため。
     * 左右キーも、奪うとパネルを出したままキャレットを動かせなくなるので処理しない。
     *
     * - Returns: 処理した場合はtrue、確定のやり直しの操作でない場合はfalse。
     */
    @MainActor private func handleRedoingFixedText(_ action: Action) -> Bool {
        guard let lastFix, lastFix.redoing, case .normal = state.inputMethod, state.specialState == nil,
              let textInput = action.textInput else {
            return false
        }
        let selecting = lastFix.selecting
        let count = selecting.candidates.count
        let displayCount = Global.displayCandidateCount
        /// 現在のページの先頭の変換候補の位置。やり直し中はインライン表示しないのでページの区切りは単純
        let pageStart = selecting.candidateIndex - selecting.candidateIndex % displayCount
        /// 次のページの先頭。最後のページなら最初のページの先頭に戻る
        let nextPageStart = pageStart + displayCount < count ? pageStart + displayCount : 0
        /// 前のページの先頭。最初のページなら最後のページの先頭に戻る
        let previousPageStart = pageStart > 0 ? pageStart - displayCount : (count - 1) - (count - 1) % displayCount
        let candidateIndex: Int
        // 上下キーの移動量は変換候補選択中と同じく変換候補リストの表示方向によって変える
        switch action.keyBind {
        case .down:
            candidateIndex = if case .vertical = Global.candidateListDirection.value {
                (selecting.candidateIndex + 1) % count
            } else {
                nextPageStart
            }
        case .up:
            candidateIndex = if case .vertical = Global.candidateListDirection.value {
                (selecting.candidateIndex - 1 + count) % count
            } else {
                previousPageStart
            }
        case .space:
            // 変換候補選択中と同じくページ送り
            candidateIndex = nextPageStart
        case .backwardCandidate:
            candidateIndex = (selecting.candidateIndex - 1 + count) % count
        default:
            // 変換候補パネルに表示している選択用のキー。修飾キーとの組み合わせは対象外
            let modifierFlags = action.event.modifierFlags
            guard !modifierFlags.contains(.control), !modifierFlags.contains(.command),
                  !modifierFlags.contains(.option), !modifierFlags.contains(.function),
                  let input = action.event.charactersIgnoringModifiers?.lowercased().first,
                  let index = Global.selectCandidateKeys.firstIndex(of: input), index < displayCount else {
                return false
            }
            // 変換候補がない位置の選択用のキーは握り潰す
            if pageStart + index < count {
                _ = redoFixedText(candidateIndex: pageStart + index, textInput: textInput)
                // 選択用のキーは変換候補選択中と同じく決定として扱う
                finishRedoFixedText()
            }
            return true
        }
        if !redoFixedText(candidateIndex: candidateIndex, textInput: textInput) {
            // 置き換えられなくなったらやり直しを終える
            finishRedoFixedText()
        }
        return true
    }

    /**
     * 確定のやり直しを終了する。
     *
     * 変換候補パネルを閉じ、遅らせていたユーザー辞書への登録を行う。
     *
     * 確定のやり直しは押すたびに変換候補を進めるため、押すたびに登録すると通過しただけの変換候補が
     * すべてユーザー辞書の先頭に積まれてしまい、その読みの変換候補の順序が壊れる。
     * 変換候補が多い読みほど影響が大きいので、やり直しが終わってから最後に選ばれた変換候補だけを登録する。
     */
    @MainActor private func finishRedoFixedText() {
        guard var lastFix, lastFix.redoing else {
            return
        }
        let selecting = lastFix.selecting
        addWordToUserDict(yomi: selecting.yomi,
                          okuri: selecting.okuri,
                          candidate: selecting.candidates[selecting.candidateIndex])
        lastFix.redoing = false
        self.lastFix = lastFix
        updateCandidates(selecting: nil)
    }

    /**
     * 状態がnormalのときのprintableイベントのhandle
     *
     * - Parameters:
     *   - input: ``Action/KeyEvent/printable(_:)`` の引数であるcharacterIgnoringModifiersな文字列
     *   - specialState: 単語登録モードや単語登録解除モード
     */
    @MainActor func handleNormalPrintable(input: String, action: Action, specialState: SpecialState?) -> Bool {
        switch state.inputMode {
        case .hiragana, .katakana, .hankaku:
            if Global.kanaRule.isPrefix(input, modifierFlags: action.event.modifierFlags, treatAsAlphabet: action.treatAsAlphabet) {
                let result = Global.kanaRule.convert(input, punctuation: Global.punctuation)
                if let moji = result.kakutei {
                    if action.shiftIsPressed() {
                        state.inputMethod = .composing(
                            ComposingState(isShift: true, text: moji.kana.map { String($0) }, romaji: result.input))
                        updateMarkedText()
                    } else if enableMarkedTextWorkaround {
                        // 確定文字を未確定文字列として入力するワークアラウンド
                        let text = moji.string(for: state.inputMode)
                        state.inputMethod = .composing(
                            ComposingState(isShift: false, text: [], romaji: "", fixedWorkaroundText: FixedWorkaroundText(text: text, displayText: text)))
                        updateMarkedText()
                    } else {
                        addFixedText(moji.string(for: state.inputMode))
                    }
                } else {
                    state.inputMethod = .composing(
                        ComposingState(isShift: action.shiftIsPressed(), text: [], okuri: nil, romaji: input))
                    updateMarkedText()
                }
            } else {
                // Option-Shift-2のような入力のときには€が入力されるようにする
                if let characters = action.characters() {
                    // lowercaseMapにエントリがある場合はエントリの方のキーが入力されたと見做す
                    if let mappedEvent = Global.kanaRule.convertKeyEvent(action.event) {
                        return handleNormal(
                            Action(keyBind: Global.keyBinding.action(event: mappedEvent, inputMode: state.inputMode, inputMethod: state.inputMethod),
                                   event: mappedEvent,
                                   textInput: action.textInput,
                                   treatAsAlphabet: true),
                            specialState: specialState)
                    }
                    let result = Global.kanaRule.convert(characters, punctuation: Global.punctuation)
                    if let moji = result.kakutei {
                        if action.shiftIsPressed() && moji.kana.isHiragana {
                            state.inputMethod = .composing(
                                ComposingState(isShift: true, text: moji.kana.map { String($0) }, romaji: result.input))
                            updateMarkedText()
                        } else {
                            addFixedText(moji.string(for: state.inputMode))
                        }
                    } else {
                        addFixedText(characters)
                    }
                }
            }
            return true
        case .eisu:
            if let characters = action.characters() {
                addFixedText(characters.toZenkaku())
            } else {
                logger.error("Can not find printable characters in keyEvent")
                return false
            }
            return true
        case .direct:
            if let characters = action.characters() {
                addFixedText(characters)
            } else {
                logger.error("Can not find printable characters in keyEvent")
                return false
            }
            return true
        }
    }

    @MainActor func handleComposing(_ action: Action, composing: ComposingState, specialState: SpecialState?) -> Bool {
        let isShift = composing.isShift
        let text = composing.text
        let okuri = composing.okuri
        let romaji = composing.romaji
        let event = action.event
        let input = event.charactersIgnoringModifiers
        let converted: Romaji.ConvertedMoji?

        // xterm.jsを利用したアプリでaiueoなどの1文字で確定するひらがなが入力できなかったり、
        // qやlのモード変更でそのまま入力されてしまう問題のワークアラウンド。
        // すでにmarkedTextがあるときは問題が起きないため、specialStateはnilじゃなければならない
        // (specialStateがあるときはfixedWorkaroundTextを使ってはいけない)
        if let fixedWorkaroundText = composing.fixedWorkaroundText, enableMarkedTextWorkaround && specialState == nil {
            addFixedText(fixedWorkaroundText.text)
            state.inputMethod = .normal
            if case .enter = action.keyBind {
                // Enterキーは単に未確定文字列の確定として使用する
                return true
            } else {
                let keyBind = Global.keyBinding.action(event: event, inputMode: .hiragana, inputMethod: .normal)
                let newAction = action.with(keyBind: keyBind)
                return handleNormal(newAction, specialState: nil)
            }
        }

        // ローマ字かな変換ルールで変換できる場合、そちらを優先する ("z " で全角スペース、"zl" で右矢印など)
        // Controlが押されているときは変換しない (s + Ctrl-a だと "さ" にはせずCtrl-aを優先する)
        // Optionが押されていても無視するようにしている (そちらのほうがうれしい人が多いかな程度の消極的理由)
        if action.keyBind == nil && (event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command)) {
            return true
        } else if let input, !event.modifierFlags.contains(.control) {
            if case .candidates(let candidateWords) = completion, let candidate = candidateWords.first, let original = candidate.original {
                // 補完候補が変換候補であり、fixedCompletionByPeriodが有効で、ピリオドキーが入力された場合先頭の補完候補で確定する
                if input == "." && !event.modifierFlags.contains(.shift) && Global.fixedCompletionByPeriod {
                    addWordToUserDict(yomi: original.midashi,  okuri: nil, candidate: candidate)
                    state.inputMethod = .normal
                    addFixedText(candidate.word)
                    return true
                }
                // 補完候補が表示されてから一定時間経過後に確定キーが押された場合は補完候補で確定する
                if let displayedAt = completionSetAt,
                   displayedAt.timeIntervalSinceNow <= -Global.completionConfirmationTimeLimit,
                   let first = input.lowercased().first,
                   let index = Global.selectCandidateKeys.firstIndex(of: first), index < candidateWords.count, index < Global.displayCandidateCount {
                    let candidate = candidateWords[index]
                    if let original = candidate.original {
                        addWordToUserDict(yomi: original.midashi, okuri: nil, candidate: candidate)
                    }
                    completion = nil
                    state.inputMethod = .normal
                    addFixedText(candidate.word)
                    return true
                }
            }
            if !input.isAlphabet, let characters = action.characters() {
                converted = useKanaRuleIfPresent(inputMode: state.inputMode, romaji: romaji, input: characters)
            } else {
                converted = useKanaRuleIfPresent(inputMode: state.inputMode, romaji: romaji, input: input)
            }
        } else {
            converted = nil
        }
        if let input, let converted {
            return handleComposingPrintable(
                input: input,
                converted: converted,
                action: action,
                composing: composing,
                specialState: specialState)
        }

        func updateModeIfPrevModeExists() {
            if let prevMode = composing.prevMode {
                state.inputMode = prevMode
                inputMethodEventSubject.send(.modeChanged(prevMode))
            }
        }

        switch action.keyBind {
        case .hiragana:
            if let converted, converted.kakutei != nil {
                break
            }
            fallthrough
        case .enter:
            // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"として変換する
            state.inputMethod = .normal
            addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
            updateModeIfPrevModeExists()
            if action.keyBind == .enter && Global.enterNewLine {
                return handle(action)
            }
            return true
        case .toggleAndFixKana:
            if text.isEmpty {
                // 入力中ローマ字を今のモードで確定してからモードを変更する
                switch state.inputMode {
                case .hiragana:
                    state.inputMethod = .normal
                    addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
                    state.inputMode = .katakana
                    inputMethodEventSubject.send(.modeChanged(.katakana))
                    return true
                case .katakana, .hankaku:
                    state.inputMethod = .normal
                    addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
                    state.inputMode = .hiragana
                    inputMethodEventSubject.send(.modeChanged(.hiragana))
                    return true
                case .eisu, .direct:
                    break
                }
            } else if okuri == nil {
                // ひらがな入力中ならカタカナ、カタカナ入力中ならひらがな、半角カタカナ入力中なら全角カタカナで確定する。
                // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"が入力されているとする
                state.inputMethod = .normal
                switch state.inputMode {
                case .hiragana:
                    let fixedText = composing.string(for: .katakana, kanaRule: Global.kanaRule)
                    if Global.registerKatakana {
                        let yomi = composing.string(for: .hiragana, kanaRule: Global.kanaRule)
                        addWordToUserDict(yomi: yomi, okuri: nil, candidate: Candidate(fixedText))
                    }
                    addFixedText(fixedText)
                    return true
                case .hankaku:
                    addFixedText(composing.string(for: .katakana, kanaRule: Global.kanaRule))
                    return true
                case .katakana:
                    addFixedText(composing.string(for: .hiragana, kanaRule: Global.kanaRule))
                    return true
                case .direct:
                    // 普通に入力させる
                    break
                default:
                    fatalError("inputMode=\(state.inputMode), handleComposingでqが入力された")
                }
            } else {
                // 送り仮名があるときはローマ字部分をリセットする
                state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                updateMarkedText()
                return true
            }
        case .hankakuKana:
            if okuri == nil {
                if case .direct = state.inputMode {
                    // 全角英数で確定する
                    state.inputMethod = .normal
                    addFixedText(text.map { $0.toZenkaku() }.joined())
                    // TODO: AquaSKKはAbbrevに入る前のモードに戻しているのでそれに合わせる?
                    state.inputMode = .hiragana
                    inputMethodEventSubject.send(.modeChanged(.hiragana))
                } else {
                    // 半角カタカナで確定する。
                    state.inputMethod = .normal
                    addFixedText(composing.string(for: .hankaku, kanaRule: nil))
                }
                return true
            } else {
                // 送り仮名があるときはなにもしない
                return true
            }
        case .toggleDirect:
            // 送り仮名の有無にかかわらず、未確定文字列を現在のモードで確定してからnormalと同じ処理をする。
            // .directと違って送り仮名があるときもモードを切り替える。
            // 修飾キー付きのキーを押してモードが切り替わらずアプリ側にキーが渡るのはトグルキーとして不自然なため。
            // composing.string(for:)はinputMode == .eisuを想定していないため、composingでinputMode == .eisuになることはない前提。
            // Abbrev中 (inputMode == .directでcomposing) はprevModeに戻してからトグルを評価するので、
            // 候補選択中に押した場合 (handleSelectingのfixCurrentSelect) と同じ結果になる。
            state.inputMethod = .normal
            addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
            updateModeIfPrevModeExists()
            return handleNormal(action, specialState: specialState)
        case .direct, .zenkaku:
            // 入力済みを確定してからlを打ったのと同じ処理をする
            if okuri == nil {
                switch state.inputMode {
                case .hiragana, .katakana, .hankaku:
                    state.inputMethod = .normal
                    addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
                    return handleNormal(action, specialState: specialState)
                case .direct:
                    // 普通にlを入力させる
                    break
                default:
                    fatalError("inputMode=\(state.inputMode), handleComposingでlが入力された")
                }
            } else {
                // 送り仮名があるときはローマ字部分をリセットする
                state.inputMethod = .composing(
                    ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                return false
            }
        case .japanese:
            if okuri == nil {
                // AquaSKKの挙動に合わせて送り無視で確定、次の入力へ進む
                switch state.inputMode {
                case .hiragana:
                    if !text.isEmpty {
                        addFixedText(text.joined())
                        state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                        updateMarkedText()
                    }
                    return true
                case .katakana, .hankaku:
                    if !text.isEmpty {
                        addFixedText(text.map { $0.toKatakana() }.joined())
                        state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
                        updateMarkedText()
                    }
                    return true
                case .direct:
                    break
                default:
                    // FIXME: KeyBindにdebugDescriptionを実装したい
                    fatalError("inputMode=\(state.inputMode), handleComposingでShift-Qが入力された")
                }
            } else {
                // 送り仮名があるときはローマ字部分をリセットする
                state.inputMethod = .composing(
                    ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                updateMarkedText()
                return true
            }
            break
        case .backspace:
            if let newComposingState = composing.dropLast() {
                state.inputMethod = .composing(newComposingState)
            } else {
                state.inputMethod = .normal
                updateModeIfPrevModeExists()
            }
            updateMarkedText()
            return true
        case .space:
            // "z " のようなスペースを使ったローマ字変換ルールがある場合は漢字変換よりも優先する
            if let converted, let input {
                return handleComposingPrintable(
                    input: input,
                    converted: converted,
                    action: action,
                    composing: composing,
                    specialState: specialState
                )
            }
            if text.isEmpty {
                // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"として変換する
                let fixedText = composing.string(for: state.inputMode, kanaRule: Global.kanaRule)
                addFixedText(fixedText + " ")
                state.inputMethod = .normal
                updateModeIfPrevModeExists()
                return true
            } else if composing.cursor == 0 {
                state.inputMethod = .normal
                updateMarkedText()
                return true
            } else {
                if state.inputMode != .direct {
                    return handleComposingStartConvert(action, composing: composing.trim(kanaRule: Global.kanaRule), specialState: specialState)
                } else {
                    return handleComposingStartConvert(action, composing: composing, specialState: specialState)
                }
            }
        case .shiftSpace:
            // 補完が読みのときは変換開始する。そうじゃないときはなにもしない
            // NOTE: 補完が変換候補のときはシフトをうっかり押しちゃっただけのspaceと同じ挙動でもいいかも?
            if case .yomi(let yomis, let yomiIndex) = completion, 0 <= yomiIndex && yomiIndex < yomis.count {
                // 最初の読みで変換開始
                let yomi = yomis[yomiIndex]
                let newText = yomi.map({ String($0) })
                let completionState = ComposingState(isShift: true,
                                                     text: newText,
                                                     okuri: nil,
                                                     romaji: "",
                                                     cursor: nil,
                                                     prevMode: composing.prevMode)
                return handleComposingStartConvert(action, composing: completionState, specialState: specialState)
            }
            return true
        case .tab:
            // FIXME: この記号がローマ字に含まれていることも考慮するべき?
            if case .yomi(let yomis, let yomiIndex) = completion {
                if action.shiftIsPressed() {
                    if yomiIndex > 1 {
                        let yomi = yomis[yomiIndex - 2]
                        let newText = yomi.map({ String($0) })
                        state.inputMethod = .composing(ComposingState(isShift: composing.isShift,
                                                                      text: newText,
                                                                      okuri: nil,
                                                                      romaji: "",
                                                                      cursor: nil,
                                                                      prevMode: composing.prevMode))
                        let nextYomiCompletion = yomis[yomiIndex - 1]
                        self.completion = .yomi(yomis, yomiIndex - 1)
                        updateMarkedText(nextCompletion: nextYomiCompletion)
                    } else {
                        // 補完候補の先頭だったらなにもしない
                        return true
                    }
                } else {
                    if yomiIndex < yomis.count {
                        // カーソル位置に関わらずカーソル位置はリセットされる
                        let yomi = yomis[yomiIndex]
                        let newText = yomi.map({ String($0) })
                        state.inputMethod = .composing(ComposingState(isShift: composing.isShift,
                                                                      text: newText,
                                                                      okuri: nil,
                                                                      romaji: "",
                                                                      cursor: nil,
                                                                      prevMode: composing.prevMode))
                        let nextYomiCompletion = yomiIndex + 1 < yomis.count ? yomis[yomiIndex + 1] : ""
                        self.completion = .yomi(yomis, yomiIndex + 1)
                        updateMarkedText(nextCompletion: nextYomiCompletion)
                    } else {
                        // 補完候補の終端だったらなにもしない
                        return true
                    }
                }
            } else if case .candidates(let candidateWords) = completion {
                let trimmedComposing = composing.trim(kanaRule: Global.kanaRule)
                let yomiText = trimmedComposing.yomi(for: self.state.inputMode, kanaRule: Global.kanaRule)
                let selectingState = SelectingState(
                    prev: SelectingState.PrevState(mode: state.inputMode, composing: trimmedComposing),
                    yomi: yomiText,
                    candidates: candidateWords,
                    candidateIndex: 0,
                    remain: composing.remain(),
                    completion: true,
                )
                updateCandidates(selecting: selectingState)
                state.inputMethod = .selecting(selectingState)
                updateMarkedText()
            }
            return true
        case .stickyShift:
            if state.inputMode == .direct {
                break
            }

            // "k;"のようなセミコロンを使ったルールがある場合はそれを優先させる
            if let input, let converted = useKanaRuleIfPresent(inputMode: state.inputMode, romaji: romaji, input: input) {
                return handleComposingPrintable(
                    input: input,
                    converted: converted,
                    action: action,
                    composing: composing,
                    specialState: specialState
                )
            }

            if okuri != nil {
                // 送り仮名入力中は無視する
                // AquaSKKは送り仮名の末尾に"；"をつけて変換処理もしくは単語登録に遷移
                return true
            } else {
                // 空文字列のときはAquaSKKと同様に全角で入力、それ以外のときは送り仮名モードへ
                // NOTE: 空文字列のときは無視する、でもいいかも?
                if text.isEmpty {
                    state.inputMethod = .normal
                    if let characters = action.characters() {
                        addFixedText(characters.toZenkaku())
                    }
                } else {
                    // ローマ字がnのときは「ん」と確定する
                    if romaji == "n" {
                        state.inputMethod = .composing(
                            ComposingState(isShift: true,
                                           text: text + [Romaji.n.kana],
                                           okuri: [],
                                           romaji: ""))
                    } else {
                        state.inputMethod = .composing(
                            ComposingState(isShift: true,
                                           text: text,
                                           okuri: [],
                                           romaji: romaji))
                    }
                    updateMarkedText()
                }
                return true
            }
        case .cancel:
            if text.isEmpty || romaji.isEmpty {
                // 下線テキストをリセットする
                state.inputMethod = .normal
                if let reconvertText = composing.reconvertText {
                    addFixedText(reconvertText)
                } else if !isShift {
                    // `n` だけ入力した状態でESC押したときは `ん` を確定させる。Shiftが押されているときは確定させない
                    addFixedText(composing.string(for: state.inputMode, kanaRule: Global.kanaRule))
                }
                updateModeIfPrevModeExists()
            } else {
                state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: nil, romaji: ""))
            }
            updateMarkedText()
            return true
        case .left:
            if okuri == nil { // 一度変換候補選択に遷移してからキャンセルで戻ると送り仮名ありになっている
                if romaji.isEmpty {
                    state.inputMethod = .composing(composing.moveCursorLeft())
                } else if text.isEmpty {
                    // 未確定ローマ字しかないときは入力前に戻す (.cancelと同じ)
                    // AquaSKKとほぼ同じだがAquaSKKはカーソル移動も機能するのでreturn falseになってそう
                    state.inputMethod = .normal
                } else {
                    // 未確定ローマ字があるときはローマ字を消す (AquaSKKと同じ)
                    state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                }
                updateMarkedText()
            }
            return true
        case .right:
            if okuri == nil { // 一度変換候補選択に遷移してからキャンセルで戻ると送り仮名ありになっている
                if romaji.isEmpty {
                    state.inputMethod = .composing(composing.moveCursorRight())
                } else if text.isEmpty {
                    // 未確定ローマ字しかないときは入力前に戻す (.cancelと同じ)
                    // AquaSKKとほぼ同じだがAquaSKKはカーソル移動も機能するのでreturn falseになってそう
                    state.inputMethod = .normal
                } else {
                    state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                }
                updateMarkedText()
            }
            return true
        case .startOfLine:
            if okuri == nil { // 一度変換候補選択に遷移してからキャンセルで戻ると送り仮名ありになっている
                if romaji.isEmpty {
                    state.inputMethod = .composing(composing.moveCursorFirst())
                } else if text.isEmpty {
                    // 未確定ローマ字しかないときは入力前に戻す (.cancelと同じ)
                    // AquaSKKとほぼ同じだがAquaSKKはカーソル移動も機能するのでreturn falseになってそう
                    state.inputMethod = .normal
                } else {
                    // 未確定ローマ字があるときはローマ字を消す (AquaSKKと同じ)
                    state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                }
                updateMarkedText()
            }
            return true
        case .endOfLine:
            if okuri == nil { // 一度変換候補選択に遷移してからキャンセルで戻ると送り仮名ありになっている
                if romaji.isEmpty {
                    state.inputMethod = .composing(composing.moveCursorLast())
                } else if text.isEmpty {
                    // 未確定ローマ字しかないときは入力前に戻す (.cancelと同じ)
                    // AquaSKKとほぼ同じだがAquaSKKはカーソル移動も機能するのでreturn falseになってそう
                    state.inputMethod = .normal
                } else {
                    state.inputMethod = .composing(ComposingState(isShift: isShift, text: text, okuri: okuri, romaji: ""))
                }
                updateMarkedText()
            }
            return true
        case .delete:
            if composing.cursor != nil {
                state.inputMethod = .composing(composing.dropForward())
                updateMarkedText()
            }
            return true
        case .affix:
            if state.inputMode == .direct {
                break
            } else if composing.text.isEmpty {
                // 接尾辞の入力開始として扱う
                let converted = Global.kanaRule.convert(romaji + ">", punctuation: Global.punctuation)
                return handleComposingPrintable(
                    input: ">",
                    converted: converted,
                    action: action,
                    composing: composing,
                    specialState: specialState)
            } else {
                // 接頭辞が入力されたものとして ">" より前で変換を開始する
                let newComposing = composing.trim(kanaRule: Global.kanaRule).appendText(Romaji.Moji(firstRomaji: "", kana: ">"))
                return handleComposingStartConvert(action, composing: newComposing, specialState: specialState)
            }
        case .up, .down, .registerPaste, .eisu, .kana, .toggleKana, .reconvert:
            return true
        case .abbrev, .directAbbrev, .unregister, .backwardCandidate, .fixNextCandidate, .fixPrevCandidate, .none:
            break
        }

        if let input {
            let converted: Romaji.ConvertedMoji
            if !input.isAlphabet, let characters = action.characters() {
                converted = Global.kanaRule.convert(romaji + characters, punctuation: Global.punctuation)
            } else {
                converted = Global.kanaRule.convert(romaji + input, punctuation: Global.punctuation)
            }

            return handleComposingPrintable(
                input: input,
                converted: converted,
                action: action,
                composing: composing,
                specialState: specialState)
        } else {
            return false
        }
    }

    /**
     * 状態がcomposingのときのprintableイベントのhandle
     *
     * - Parameters:
     *   - input: NSEvent.characterIgnoringModifiersと同等
     *   - converted: ローマ字変換結果
     *   - action: キー入力
     *   - composing: 現在の状態
     *   - specialState: 単語登録モードや単語登録解除モード
     */
    @MainActor func handleComposingPrintable(
        input: String, converted: Romaji.ConvertedMoji, action: Action, composing: ComposingState,
        specialState: SpecialState?
    ) -> Bool {
        let isShift = composing.isShift
        let text = composing.text
        let okuri = composing.okuri

        switch state.inputMode {
        case .hiragana, .katakana, .hankaku:
            // ローマ字が確定してresult.inputがない
            // StickyShiftでokuriが[]になっている、またはShift押しながら入力した
            if let moji = converted.kakutei {
                if converted.input.isEmpty {
                    // いまの入力が送り仮名とならないことを判定
                    // まだ読み部分が空ならば常に送り仮名ではない
                    // シフトを押しながら入力した文字がアルファベットじゃないなら送り仮名ではない (記号なので)
                    // 未確定文字列の先頭にカーソルがあるときはシフト押していてもいなくても送り仮名ではない
                    if text.isEmpty || (okuri == nil && !(action.shiftIsPressed() && moji.kana.isHiragana)) || composing.cursor == 0 {
                        if isShift || (action.shiftIsPressed() && moji.kana.isHiragana) {
                            // シフトを押しながら入力し、`gq,が<okuri>い` のように送り仮名ありのルールを含んでいる場合は送り仮名あり
                            if let ruleOkuri = Global.kanaRule.okuriTable[composing.romaji + input], action.shiftIsPressed() {
                                // <okuri> ルール + シフトあり
                                let yomi = String(moji.kana.dropLast(ruleOkuri.kana.count))
                                if text.isEmpty && !isShift {
                                    // 通常モードから <okuri> ルール + シフトあり → かなを確定出力し okuri かなを読みとして composing 開始
                                    addFixedText(Romaji.Moji(firstRomaji: moji.firstRomaji, kana: yomi).string(for: state.inputMode))
                                    state.inputMethod = .composing(
                                        ComposingState(isShift: true, text: ruleOkuri.kana.map { String($0) }, romaji: ""))
                                    updateMarkedText()
                                    return true
                                }
                                // composingモードから <okuri> ルール + シフトあり → 辞書変換起動
                                let convertComposing = ComposingState(isShift: true,
                                                                      text: composing.text + [yomi],
                                                                      okuri: [ruleOkuri],
                                                                      romaji: "")
                                return handleComposingStartConvert(action, composing: convertComposing, specialState: specialState)
                            }
                            state.inputMethod = .composing(composing.appendText(moji).resetRomaji().with(isShift: true))
                        } else {
                            state.inputMethod = .normal
                            addFixedText(moji.string(for: state.inputMode))
                            return true
                        }
                    } else {
                        // 送り仮名が1文字以上確定した時点で変換を開始する
                        // 変換候補がないときは辞書登録へ
                        // カーソル位置がnilじゃないときはその前までで変換を試みる
                        // 自動送り仮名検出かつ <okuri> ルールがある場合のみ自動分割
                        if okuri == nil, let ruleOkuri = Global.kanaRule.okuriTable[composing.romaji + input] {
                            // <okuri> ルール: kana から okuri を除いた部分をよみに追加し ruleOkuri を送り仮名として変換開始
                            // カーソルがある場合はカーソル位置に挿入してカーソルを進める
                            let yomi = String(moji.kana.dropLast(ruleOkuri.kana.count))
                            let yomiMojis = yomi.map { String($0) }
                            let newText: [String]
                            if let cursor = composing.cursor {
                                newText = Array(composing.text[0..<cursor]) + yomiMojis + Array(composing.text[cursor...])
                            } else {
                                newText = composing.text + yomiMojis
                            }
                            let newComposing = ComposingState(isShift: true,
                                                              text: newText,
                                                              okuri: [ruleOkuri],
                                                              romaji: "",
                                                              cursor: composing.cursor.map({ $0 + yomi.count }))
                            return handleComposingStartConvert(action, composing: newComposing, specialState: specialState)
                        }
                        let newComposing = ComposingState(isShift: true,
                                                          text: composing.text,
                                                          okuri: (okuri ?? []) + [moji],
                                                          romaji: "",
                                                          cursor: composing.cursor)
                        return handleComposingStartConvert(action, composing: newComposing, specialState: specialState)
                    }
                } else {  // !converted.input.isEmpty
                    // n + 母音以外を入力して「ん」が確定したときや同一の子音を連続入力して促音が確定したときなど
                    if isShift {
                        let newComposingState: ComposingState
                        if let okuri {
                            newComposingState = ComposingState(isShift: true,
                                                               text: text,
                                                               okuri: okuri + [moji],
                                                               romaji: converted.input)
                        } else {
                            newComposingState = ComposingState(isShift: true,
                                                               text: composing.subText() + [moji.kana] + (composing.remain() ?? []),
                                                               okuri: action.shiftIsPressed() ? [] : nil,
                                                               romaji: converted.input,
                                                               cursor: composing.cursor.map { $0 + 1 })
                        }
                        if let inputConverted = useKanaRuleIfPresent(inputMode: state.inputMode, romaji: converted.input, input: "") {
                            return handleComposingPrintable(input: inputConverted.input,
                                                            converted: inputConverted,
                                                            action: action,
                                                            composing: newComposingState,
                                                            specialState: specialState)
                        } else {
                            state.inputMethod = .composing(newComposingState)
                        }
                    } else {
                        addFixedText(moji.string(for: state.inputMode))
                        state.inputMethod = .normal
                        return handleNormalPrintable(input: converted.input, action: action, specialState: specialState)
                    }
                }
                updateMarkedText()
            } else if Global.kanaRule.isPrefix(input, modifierFlags: action.event.modifierFlags, treatAsAlphabet: action.treatAsAlphabet) {
                // ローマ字の一部が入力された場合
                // シフトが押されているかどうかで送り仮名入力かそうでないかに分岐
                if !text.isEmpty && okuri == nil && action.shiftIsPressed() && composing.cursor != 0 {
                    state.inputMethod = .composing(
                        ComposingState(isShift: isShift,
                                       text: text,
                                       okuri: [],
                                       romaji: converted.input,
                                       cursor: composing.cursor))
                } else {
                    state.inputMethod = .composing(
                        ComposingState(isShift: isShift,
                                       text: text,
                                       okuri: okuri,
                                       romaji: converted.input,
                                       cursor: composing.cursor))
                }
                updateMarkedText()
            } else {
                // lowercaseMapにエントリがある場合はエントリの方のキーが入力されたと見做す
                if let mappedEvent = Global.kanaRule.convertKeyEvent(action.event) {
                    return handleComposing(
                        Action(keyBind: Global.keyBinding.action(event: mappedEvent, inputMode: state.inputMode, inputMethod: state.inputMethod),
                               event: mappedEvent,
                               textInput: action.textInput,
                               treatAsAlphabet: true),
                        composing: composing,
                        specialState: specialState
                    )
                }
                // 非ローマ字で特殊な記号でない場合。数字が読みとして使われている場合などを想定。
                if okuri == nil {
                    // ローマ字が残っていた場合は消去してキー入力をそのままくっつける
                    if let characters = action.characters() {
                        state.inputMethod = .composing(composing.resetRomaji().appendText(Romaji.Moji(firstRomaji: "", kana: characters)))
                    } else {
                        state.inputMethod = .composing(composing.resetRomaji().appendText(Romaji.Moji(firstRomaji: "", kana: input)))
                    }
                    updateMarkedText()
                } else {
                    // 送り仮名入力モード時は入力しなかった扱いとする
                    return true
                }
            }
            return true
        case .direct:
            if let characters = action.characters() {
                state.inputMethod = .composing(composing.appendText(Romaji.Moji(firstRomaji: "", kana: characters)))
                updateMarkedText()
            }
            return true
        default:
            fatalError("inputMode=\(state.inputMode), handleComposingで\(input)が入力された")
        }
    }

    @MainActor private func useKanaRuleIfPresent(inputMode: InputMode, romaji: String, input: String) -> Romaji.ConvertedMoji? {
        if inputMode != .direct && !romaji.isEmpty {
            let converted = Global.kanaRule.convert(romaji + input, punctuation: Global.punctuation)
            if converted.kakutei != nil && converted.input == "" {
                return converted
            } else {
                return nil
            }
        } else {
            return nil
        }
    }

    @MainActor func handleComposingStartConvert(_ action: Action, composing: ComposingState, specialState: SpecialState?) -> Bool {
        // 未確定ローマ字はn以外は入力されずに削除される. nだけは"ん"として変換する
        // 変換候補がないときは辞書登録へ
        let trimmedComposing = composing.trim(kanaRule: Global.kanaRule)
        var yomiText = trimmedComposing.yomi(for: self.state.inputMode, kanaRule: Global.kanaRule)
        let candidateWords: [Candidate]
        // FIXME: Abbrevモードでも接頭辞、接尾辞を検索するべきか再検討する。
        // いまは ">"で終わる・始まる場合は、Abbrevモードであっても接頭辞・接尾辞を探しているものとして検索する
        // ">" 単体のように ">" を除くと読みが空になる場合は接頭辞・接尾辞変換とはみなさず、
        // ">" をそのまま見出しとして通常変換する (ddskkと同様)。空見出しでの辞書登録を防ぐ。
        if yomiText.hasSuffix(">") && yomiText.count > 1 {
            yomiText = String(yomiText.dropLast())
            candidateWords = candidates(for: yomiText, option: .prefix) + candidates(for: yomiText, option: nil)
        } else if yomiText.hasPrefix(">") && yomiText.count > 1 {
            yomiText = String(yomiText.dropFirst())
            candidateWords = candidates(for: yomiText, option: .suffix) + candidates(for: yomiText, option: nil)
        } else if let okuri = composing.okuri, !okuri.isEmpty {
            candidateWords = candidates(for: yomiText, option: .okuri(okuri.map { $0.kana }.joined()))
        } else {
            candidateWords = candidates(for: yomiText, option: nil)
        }
        if candidateWords.isEmpty {
            if case .register(let registerState, let prev) = specialState {
                // 単語登録中に単語登録する
                state.specialState = .register(
                    RegisterState(
                        prev: RegisterState.PrevState(mode: state.inputMode, composing: trimmedComposing),
                        yomi: yomiText),
                    prev: prev + [registerState])
                state.inputMethod = .normal
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
            } else {
                // 単語登録に遷移する
                state.specialState = .register(
                    RegisterState(
                        prev: RegisterState.PrevState(mode: state.inputMode, composing: trimmedComposing),
                        yomi: yomiText),
                    prev: [])
                state.inputMethod = .normal
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
            }
        } else {
            let selectingState = SelectingState(
                prev: SelectingState.PrevState(mode: state.inputMode, composing: trimmedComposing),
                yomi: yomiText,
                candidates: candidateWords,
                candidateIndex: 0,
                remain: composing.remain(),
                completion: false,
            )
            updateCandidates(selecting: selectingState)
            state.inputMethod = .selecting(selectingState)
        }
        updateMarkedText()
        return true
    }

    @MainActor func handleSelecting(_ action: Action, selecting: SelectingState, specialState: SpecialState?) -> Bool {
        /**
         * 選択中の変換候補で確定
         */
        func fixCurrentSelect(yomi: String = selecting.yomi, okuri: String? = selecting.okuri, selecting: SelectingState = selecting, dropLast: Bool = false) {
            // 一文字の変換でバックスペースで確定した場合など、利用者が変換をキャンセルする意図と思われるときは辞書登録しない
            // 二文字以上の変換でバックスペースで確定した場合などは、削除された一文字を含む変換候補として辞書登録する
            // (ddskkと同様)
            let fixedText = selecting.fixedText(dropLast: dropLast)
            if !fixedText.isEmpty {
                addWordToUserDict(yomi: yomi, okuri: okuri, candidate: selecting.candidates[selecting.candidateIndex])
            }
            updateCandidates(selecting: nil)
            if let remain = selecting.remain {
                addFixedText(fixedText)
                state.inputMethod = .composing(ComposingState(isShift: true, text: remain, romaji: ""))
                updateMarkedText()
            } else {
                state.inputMethod = .normal
                addFixedText(fixedText)
                // 直前の確定の差し替えのために確定内容を覚えておく。
                // 単語登録中はクライアントに文字列を送らない (登録中の文字列に追加される) ので対象外。
                // バックスペースで末尾を削って確定した場合は変換候補と確定文字列が一致しないので対象外。
                if state.specialState == nil && !fixedText.isEmpty && !dropLast {
                    lastFix = LastFix(selecting: selecting, location: nil, text: fixedText, previousText: nil)
                }
                if let prevMode = selecting.prev.composing.prevMode {
                    state.inputMode = prevMode
                    inputMethodEventSubject.send(.modeChanged(prevMode))
                }
            }
        }

        switch action.keyBind {
        case .hiragana:
            // 選択中の変換候補で確定
            fixCurrentSelect()
            return true
        case .enter:
            // 選択中の変換候補で確定
            fixCurrentSelect()
            if Global.enterNewLine {
                return handle(action)
            }
            return true
        case .backspace:
            switch Global.selectingBackspace {
            case .cancel:
                let diff: Int
                if selecting.candidateIndex >= inlineCandidateCount {
                    // 前ページの先頭
                    diff =
                        -((selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount) - Global.displayCandidateCount
                } else {
                    diff = -1
                }
                return handleSelectingPrevious(diff: diff, selecting: selecting)
            case .dropLastInlineOnly:
                if selecting.candidateIndex >= inlineCandidateCount {
                    // 前ページの先頭
                    let diff =
                        -((selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount) - Global.displayCandidateCount
                    return handleSelectingPrevious(diff: diff, selecting: selecting)
                } else {
                    // インライン選択中は変換候補の末尾を一字消して確定
                    fixCurrentSelect(dropLast: true)
                    return true
                }
            case .dropLastAlways:
                // 変換候補の末尾を一字消して確定
                fixCurrentSelect(dropLast: true)
                return true
            case .backwardCandidate:
                // 前候補キーと同じ動き
                return handleSelectingPrevious(diff: -1, selecting: selecting)
            }
        case .up:
            if case .vertical = Global.candidateListDirection.value {
                return handleSelectingPrevious(diff: -1, selecting: selecting)
            } else {
                return handleSelectingPreviousPage(selecting: selecting)
            }
        case .down:
            if case .vertical = Global.candidateListDirection.value {
                return handleSelectingNext(action, diff: 1, selecting: selecting, specialState: specialState)
            } else {
                return handleSelectingNextPage(action, selecting: selecting, specialState: specialState)
            }
        case .space, .shiftSpace:
            if selecting.completion {
                // TODO 補完を中断して現在の読みで変換開始する
                return true
            }
            return handleSelectingNextPage(action, selecting: selecting, specialState: specialState)
        case .backwardCandidate:
            return handleSelectingPrevious(diff: -1, selecting: selecting)
        case .tab:
            if selecting.completion {
                if action.shiftIsPressed() {
                    // 補完候補を前に戻す
                    return handleSelectingPrevious(diff: -1, selecting: selecting)
                } else {
                    // 補完候補を次に進める
                    return handleSelectingNext(action, diff: 1, selecting: selecting, specialState: specialState)
                }
            }
            return true
        case .stickyShift, .hankakuKana:
            fixCurrentSelect()
            return handle(action)
        case .cancel:
            // 送り仮名がある場合は読みに結合する。例えば `Na I` という入力("な*い")をしてからキャンセルするときは
            // `Nai` という入力をしたときの状態に戻す。
            state.inputMethod = .composing(selecting.prev.composing.uniteOkuri())
            state.inputMode = selecting.prev.mode
            updateCandidates(selecting: nil)
            updateMarkedText()
            return true
        case .left:
            if case .vertical = Global.candidateListDirection.value {
                return handleSelectingPreviousPage(selecting: selecting)
            } else {
                return handleSelectingPrevious(diff: -1, selecting: selecting)
            }
        case .right:
            if case .vertical = Global.candidateListDirection.value {
                return handleSelectingNextPage(action, selecting: selecting, specialState: specialState)
            } else {
                return handleSelectingNext(action, diff: 1, selecting: selecting, specialState: specialState)
            }
        case .startOfLine:
            // 現ページの先頭
            let diff = -(selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount
            if diff < 0 {
                let newSelectingState = selecting.addCandidateIndex(diff: diff)
                state.inputMethod = .selecting(newSelectingState)
                updateCandidates(selecting: newSelectingState)
                updateMarkedText()
            }
            return true
        case .endOfLine:
            // 現ページの末尾
            let diff = min(
                Global.displayCandidateCount - (selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount,
                selecting.candidates.count - selecting.candidateIndex - 1
            )
            if diff > 0 {
                let newSelectingState = selecting.addCandidateIndex(diff: diff)
                state.inputMethod = .selecting(newSelectingState)
                updateCandidates(selecting: newSelectingState)
                updateMarkedText()
            }
            return true
        case .unregister:
            let prevRegisterState: (RegisterState, [RegisterState])?
            if case .register(let registerState, let prev) = specialState {
                prevRegisterState = (registerState, prev)
            } else {
                prevRegisterState = nil
            }
            state.specialState = .unregister(
                UnregisterState(prev: UnregisterState.PrevState(mode: state.inputMode, selecting: selecting)),
                prev: prevRegisterState)
            state.inputMethod = .normal
            state.inputMode = .direct
            updateCandidates(selecting: nil)
            updateMarkedText()
            return true
        case .affix:
            // 選択中候補で確定し、接尾辞入力に移行。
            // カーソル位置より右に文字列がある場合は接頭辞入力として扱う (無視してもいいかも)
            addWordToUserDict(yomi: selecting.yomi, okuri: selecting.okuri, candidate: selecting.candidates[selecting.candidateIndex])
            updateCandidates(selecting: nil)
            addFixedText(selecting.fixedText(dropLast: false))
            if let remain = selecting.remain {
                state.inputMethod = .composing(ComposingState(isShift: true, text: remain, romaji: ""))
                updateMarkedText()
            } else {
                state.inputMethod = .composing(ComposingState(isShift: true, text: [], okuri: nil, romaji: ""))
            }
            return handle(action)
        case .registerPaste, .delete, .eisu, .kana, .reconvert:
            return true
        case .toggleKana, .toggleAndFixKana, .direct, .toggleDirect, .zenkaku, .abbrev, .directAbbrev, .japanese, .fixNextCandidate, .fixPrevCandidate:
            break
        case nil:
            break
        }

        if let input = action.event.charactersIgnoringModifiers {
            if selecting.candidateIndex >= inlineCandidateCount {
                if let first = input.lowercased().first, let index = Global.selectCandidateKeys.firstIndex(of: first), index < Global.displayCandidateCount {
                    let diff = index - (selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount
                    if selecting.candidateIndex + diff < selecting.candidates.count {
                        let newSelecting = selecting.addCandidateIndex(diff: diff)
                        fixCurrentSelect(selecting: newSelecting)
                        return true
                    }
                }
            }
        }
        // ここまでのどれにも該当しない入力のときは、選択中候補で確定して未処理のアクションとして処理する
        fixCurrentSelect()
        return handle(action)
    }

    @MainActor private func handleSelectingPrevious(diff: Int, selecting: SelectingState) -> Bool {
        if selecting.candidateIndex + diff >= 0 {
            let newSelectingState = selecting.addCandidateIndex(diff: diff)
            updateCandidates(selecting: newSelectingState)
            state.inputMethod = .selecting(newSelectingState)
        } else if selecting.completion {
            // 変換候補の表示中は先頭のときは何もしない
            return true
        } else {
            updateCandidates(selecting: nil)
            // 送り仮名がある場合は読みに結合する。例えば `Na I` という入力("な*い")をしてからキャンセルするときは
            // `Nai` という入力をしたときの状態に戻す。
            state.inputMethod = .composing(selecting.prev.composing.uniteOkuri())
            state.inputMode = selecting.prev.mode
        }
        updateMarkedText()
        return true
    }

    @MainActor private func handleSelectingNext(_ action: Action, diff: Int, selecting: SelectingState, specialState: SpecialState?) -> Bool {
        if selecting.candidateIndex + diff < selecting.candidates.count {
            let newSelectingState = selecting.addCandidateIndex(diff: diff)
            state.inputMethod = .selecting(newSelectingState)
            updateCandidates(selecting: newSelectingState)
        } else {
            if case .register(let registerState, let prev) = specialState {
                state.specialState = .register(RegisterState(
                    prev: RegisterState.PrevState(
                        mode: selecting.prev.mode,
                        composing: selecting.prev.composing,
                        selecting: selecting),
                    yomi: selecting.yomi),
                prev: prev + [registerState])
                state.inputMethod = .normal
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
            } else if specialState != nil {
                state.inputMethod = .normal
                state.inputMode = selecting.prev.mode
            } else if selecting.completion {
                // 変換候補の表示中は終端のときに何も行わない
                return true
            } else {
                state.specialState = .register(
                    RegisterState(
                        prev: RegisterState.PrevState(
                            mode: selecting.prev.mode,
                            composing: selecting.prev.composing,
                            selecting: selecting),
                        yomi: selecting.yomi),
                    prev: [])
                state.inputMethod = .normal
                state.inputMode = .hiragana
                inputMethodEventSubject.send(.modeChanged(.hiragana))
            }
            updateCandidates(selecting: nil)
        }
        updateMarkedText()
        return true
    }

    /**
     * 選択候補をインライン表示中なら一つ前、リスト表示なら前ページの先頭へ動かす。
     * すでに変換候補の先頭だった場合は読み入力に戻す。
     */
    @MainActor private func handleSelectingPreviousPage(selecting: SelectingState) -> Bool {
        if selecting.candidateIndex >= inlineCandidateCount {
            // 前ページの先頭
            let diff = -((selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount) - Global.displayCandidateCount
            return handleSelectingPrevious(diff: diff, selecting: selecting)
        } else {
            return handleSelectingPrevious(diff: -1, selecting: selecting)
        }
    }

    /**
     * 選択候補がインライン表示なら一つ先、リスト表示なら次ページの先頭へ動かす。
     * 次ページがなければ単語登録に遷移する。
     */
    @MainActor private func handleSelectingNextPage(_ action: Action, selecting: SelectingState, specialState: SpecialState?) -> Bool {
        if selecting.candidateIndex >= inlineCandidateCount {
            let diff = Global.displayCandidateCount - (selecting.candidateIndex - inlineCandidateCount) % Global.displayCandidateCount
            return handleSelectingNext(action, diff: diff, selecting: selecting, specialState: specialState)
        } else {
            return handleSelectingNext(action, diff: 1, selecting: selecting, specialState: specialState)
        }
    }

    func setMode(_ mode: InputMode) {
        state.inputMode = mode
    }

    /// 現在の入力中文字列を確定して状態を入力前に戻す。カーソル位置が文字列の途中でも末尾にあるものとして扱う
    ///
    /// 仕様はどうあるべきか検討中。不明なものは仮としている。
    /// - 状態がNormalおよびローマ字未確定入力中
    ///   - 空文字列で確定させる
    ///   - nだけ入力してるときも空文字列 (仮)
    /// - 状態がComposing (未確定)
    ///   - "▽" より後ろの文字列を確定で入力する
    /// - 状態がSelecting (変換候補選択中)
    ///   - 現在選択中の変換候補の "▼" より後ろの文字列を確定で入力する
    ///   - ユーザー辞書には登録しない (仮)
    /// - 状態が上記でないときは仮で次のように実装してみる。いろんなソフトで不具合があるかどうかを見る
    ///   - 状態がRegister (単語登録中)
    ///     - 空文字列で確定する
    ///   - 状態がUnregister (ユーザー辞書から削除するか質問中)
    ///     - 空文字列で確定する
    @MainActor func commitComposition() {
        // 入力中状態がなくても、確定のやり直しの後始末はしておく
        finishRedoFixedText()
        if state.specialState != nil {
            state.inputMethod = .normal
            state.specialState = nil
            addFixedText("")
        } else {
            switch state.inputMethod {
            case .normal:
                return
            case .composing(let composing):
                let fixedText = composing.string(for: state.inputMode, kanaRule: nil)
                state.inputMethod = .normal
                addFixedText(fixedText)
            case .selecting(let selecting):
                // エンター押したときと違って辞書登録はスキップ (仮)
                updateCandidates(selecting: nil)
                state.inputMethod = .normal
                addFixedText(selecting.fixedText(dropLast: false))
            }
        }
    }

    private func addFixedText(_ text: String) {
        // 直前の確定の差し替えは変換候補選択から確定した直後のみ有効。
        // 呼び出し元のfixCurrentSelectがこのメソッドを呼んだあとに設定し直す。
        lastFix = nil
        if let specialState = state.specialState {
            // state.markedTextを更新してinputMethodEventSubjectにstate.displayText()をsendする
            state.specialState = specialState.appendText(text)
            updateMarkedText()
        } else {
            if text.isEmpty {
                // 空文字列で確定するときは先にmarkedTextを削除する
                // (そうしないとエディタには未確定文字列が残ってしまう)
                inputMethodEventSubject.send(.markedText(MarkedText([])))
            } else {
                inputMethodEventSubject.send(.fixedText(text))
                yomiEventSubject.send(.other(""))
            }
        }
    }

    /**
     * 現在のMarkedText状態をinputMethodEventSubject.sendする
     *
     * - Parameter nextCompletion: 次の読みの補完要素。Tabキー入力による補完が発生した場合のみ渡される。
     */
    private func updateMarkedText(nextCompletion: String? = nil) {
        inputMethodEventSubject.send(.markedText(state.displayText()))
        // 読み部分を取得してyomiEventに通知する
        if case let .composing(composing) = state.inputMethod, composing.okuri == nil {
            // ComposingState#yomi(for:) とComposingState#subText()の違いは未確定ローマ字が"n"のときに「ん」として扱うか否か
            let yomi = composing.subText().joined()
            if let nextCompletion {
                // 次の読みの補完候補 (ない場合は空文字列) を送信する。
                // 補完候補が読みでなく見出し候補のときはなにも送信しない
                if case .yomi = self.completion {
                    yomiEventSubject.send(.completed(nextCompletion))
                }
            } else {
                yomiEventSubject.send(.other(yomi))
            }
        } else {
            yomiEventSubject.send(.other(""))
        }
    }

    /// 現在の変換候補選択状態をcandidateEventSubject.sendする
    ///
    /// - Parameter inlineCandidateCount: 変換候補パネルを表示せずインライン表示する変換候補の数。
    ///   nilのときはプロパティの値を使う。確定のやり直しのように常にパネルを表示したいときは0を渡す。
    @MainActor private func updateCandidates(selecting: SelectingState?, inlineCandidateCount: Int? = nil) {
        let inlineCandidateCount = inlineCandidateCount ?? self.inlineCandidateCount
        if let selecting {
            if selecting.candidateIndex < inlineCandidateCount {
                candidateEventSubject.send(
                    Candidates(page: nil,
                               selected: selecting.candidates[selecting.candidateIndex]))
            } else {
                var start = selecting.candidateIndex - inlineCandidateCount
                let currentPage = start / Global.displayCandidateCount
                let totalPageCount = (selecting.candidates.count - inlineCandidateCount - 1) / Global.displayCandidateCount + 1
                start = start - start % Global.displayCandidateCount + inlineCandidateCount
                let candidates = selecting.candidates[start..<min(start + Global.displayCandidateCount, selecting.candidates.count)]
                candidateEventSubject.send(
                    Candidates(page: Candidates.Page(words: Array(candidates), current: currentPage, total: totalPageCount),
                               selected: selecting.candidates[selecting.candidateIndex]))
            }
        } else {
            candidateEventSubject.send(nil)
        }
    }

    /// 見出し語で辞書を引く。同じ文字列である変換候補が複数の辞書にある場合は最初の1つにまとめる。
    /// 「う゛」は「ゔ」にしてから引く
    @MainActor func candidates(for yomi: String, option: DictReferringOption? = nil) -> [Candidate] {
        return Global.dictionary.referDicts(yomi.replacing("う゛", with: "ゔ"), option: option)
    }

    /// 単語登録中から候補選択に戻る
    @MainActor private func backToSelectingFromRegister(registerState: RegisterState, prevRegisterStates: [RegisterState]) {
        state.inputMode = registerState.prev.mode
        state.specialState = prevRegisterStates.last.map { .register($0, prev: prevRegisterStates.dropLast()) }
        if let selectingState = registerState.prev.selecting {
            state.inputMethod = .selecting(selectingState)
            updateCandidates(selecting: selectingState)
        } else {
            state.inputMethod = .composing(registerState.prev.composing.uniteOkuri())
            updateCandidates(selecting: nil)
        }
        updateMarkedText()
    }

    /**
     * ユーザー辞書にエントリを追加します。
     *
     * 他の辞書から選択した変換を追加する場合はその辞書の注釈は保存しないこと。
     *
     * - Parameters:
     *   - yomi: ユーザーが入力した見出し語。送り仮名を含むときは "いr" のように送り仮名の一文字目の母音を除いたローマ字。整数変換エントリの辞書の見出しは "だい#" のような形式だが、この値は "だい5" のようにユーザーが入力したときの文字列なので "#" を含まない。
     *   - okuri: 送り仮名として確定したひらがな。"A Ru" のように入力した場合 "る" の部分。
     *   - candidate: 追加したい変換候補
     */
    @MainActor func addWordToUserDict(
        yomi: String,
        okuri: String?,
        candidate: Candidate,
        annotation: Annotation? = nil,
        source: UserDictAddSource = .conversion
    ) {
        if candidate.saveToUserDict {
            Global.dictionary.add(yomi: candidate.toMidashiString(yomi: yomi),
                                  word: Word(candidate.candidateString, okuri: okuri, annotation: annotation),
                                  source: source)
        }
    }

    /// StateMachine外で選択されている変換候補が更新されたときに通知される
    @MainActor func didSelectCandidate(_ candidate: Candidate, textInput: (any IMKTextInput)? = nil) {
        if case .selecting(var selecting) = state.inputMethod {
            if let candidateIndex = selecting.candidates.firstIndex(of: candidate) {
                selecting.candidateIndex = candidateIndex
                state.inputMethod = .selecting(selecting)
                updateMarkedText()
            }
        } else if let lastFix, lastFix.redoing, let textInput {
            // 確定のやり直し中に変換候補パネルから選択された。
            // 自分でパネルに反映したときも通知されるので、選択中の変換候補と同じときはなにもしない
            if let candidateIndex = lastFix.selecting.candidates.firstIndex(of: candidate),
               candidateIndex != lastFix.selecting.candidateIndex {
                _ = redoFixedText(candidateIndex: candidateIndex, textInput: textInput)
            }
        }
    }

    /// StateMachine外で選択されている変換候補が二回選択されたときに通知される
    @MainActor func didDoubleSelectCandidate(_ candidate: Candidate) {
        if case .selecting(let selecting) = state.inputMethod {
            addWordToUserDict(yomi: selecting.yomi, okuri: selecting.okuri, candidate: candidate)
            updateCandidates(selecting: nil)
            state.inputMethod = .normal
            addFixedText(candidate.word)
        } else {
            // 確定のやり直し中はすでにクライアントに書き込み済みなので、やり直しを終了するだけでよい
            finishRedoFixedText()
        }
    }
}

extension StateMachine: CompletionStateProtocol {
    /// 読み入力中(送り仮名なし)ならその読み文字列。それ以外(変換中・送り仮名入力中・未入力)はnil。
    @MainActor var currentComposingYomi: String? {
        // okuri == nilのチェックはupdateMarkedTextの補完条件と合わせるため(送り仮名入力中は補完しない)
        if case .composing(let composing) = state.inputMethod, composing.okuri == nil {
            return composing.yomi(for: .hiragana, kanaRule: Global.kanaRule)
        }
        return nil
    }
}
