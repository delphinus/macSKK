// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import macSKK

final class DateConversionTests: XCTestCase {
    func testInit() {
        XCTAssertNotNil(DateConversion(dict: ["format": "yyyy-MM-dd", "locale": "ja_JP", "calendar": "gregorian"]))
        XCTAssertNil(DateConversion(dict: ["format": "", "locale": "ja_JP", "calendar": "gregorian"])) // 書式が空文字列
        XCTAssertNil(DateConversion(dict: ["format": "yyyy-MM-dd", "locale": "xx_XX", "calendar": "gregorian"])) // localeが不正
        XCTAssertNil(DateConversion(dict: ["format": "yyyy-MM-dd", "locale": "ja_JP", "calendar": "xxxx"])) // calendarが不正
    }

    func testEncodeAndDecode() throws {
        let conversion = try XCTUnwrap(DateConversion(dict: ["format": "yyyy-MM-dd", "locale": "ja_JP", "calendar": "gregorian"]))
        let decoded = try XCTUnwrap(DateConversion(dict: conversion.encode()))
        XCTAssertEqual(decoded.format, conversion.format)
        XCTAssertEqual(decoded.locale, conversion.locale)
        XCTAssertEqual(decoded.calendar, conversion.calendar)
        XCTAssertNotEqual(decoded.id, conversion.id) // idは毎回再生成されるので一致しない
    }
}
