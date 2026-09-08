// SPDX-FileCopyrightText: 2026 mtgto <hogerappa@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import InputMethodKit

/**
 * テスト用のIMKTextInput実装。クライアント (テキストを編集しているアプリ) を模倣する。
 *
 * 確定文字列だけを保持し、未確定文字列 (setMarkedText) は保持しない。
 * 現在のmacSKKは未確定文字列の位置指定を使っていないため、テストに必要なのは確定文字列の状態だけ。
 */
final class MockTextInput: NSObject, IMKTextInput {
    /// クライアントが持っている確定済みのテキスト
    private(set) var text: String
    /// キャレット位置 (UTF-16でのオフセット)。選択範囲は持たない
    private(set) var caret: Int
    /// insertTextのreplacementRangeを解釈するかどうか。
    /// falseのときはターミナルなど範囲指定に対応していないクライアントを模倣してキャレット位置に挿入する
    let supportsReplacementRange: Bool
    /// selectedRangeでNSNotFoundを返すかどうか。カーソル位置を返さないクライアントを模倣する
    let supportsSelectedRange: Bool
    /// setMarkedTextで渡された未確定文字列
    private(set) var markedText: String = ""

    init(text: String = "", supportsReplacementRange: Bool = true, supportsSelectedRange: Bool = true) {
        self.text = text
        self.caret = (text as NSString).length
        self.supportsReplacementRange = supportsReplacementRange
        self.supportsSelectedRange = supportsSelectedRange
    }

    /// カーソルを移動する。確定直後でない状態を作るために使う
    func moveCaret(to location: Int) {
        caret = location
    }

    // MARK: - IMKTextInput
    func insertText(_ string: Any!, replacementRange: NSRange) {
        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let mutable = NSMutableString(string: text)
        let range: NSRange
        if supportsReplacementRange && replacementRange.location != NSNotFound {
            range = replacementRange
        } else {
            range = NSRange(location: caret, length: 0)
        }
        mutable.replaceCharacters(in: range, with: inserted)
        text = mutable as String
        caret = range.location + (inserted as NSString).length
        markedText = ""
    }

    func insertText(_ string: Any!) {
        insertText(string, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }

    func selectedRange() -> NSRange {
        if supportsSelectedRange {
            return NSRange(location: caret, length: 0)
        } else {
            return NSRange(location: NSNotFound, length: NSNotFound)
        }
    }

    func markedRange() -> NSRange {
        NSRange(location: NSNotFound, length: NSNotFound)
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        let nsText = text as NSString
        guard range.location != NSNotFound, range.location + range.length <= nsText.length else {
            return nil
        }
        return NSAttributedString(string: nsText.substring(with: range))
    }

    func length() -> Int {
        (text as NSString).length
    }

    func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int {
        NSNotFound
    }

    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        [:]
    }

    func validAttributesForMarkedText() -> [Any]! {
        []
    }

    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}

    func selectMode(_ modeIdentifier: String!) {}

    func supportsUnicode() -> Bool { true }

    func bundleIdentifier() -> String! { "net.mtgto.inputmethod.macSKKTests" }

    func windowLevel() -> CGWindowLevel { 0 }

    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }

    func uniqueClientIdentifierString() -> String! { "macSKKTests" }

    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        attributedSubstring(from: range)?.string
    }

    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect {
        .zero
    }
}
