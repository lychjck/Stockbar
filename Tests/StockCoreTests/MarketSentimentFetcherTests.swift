import XCTest
@testable import StockCore

final class MarketSentimentFetcherTests: XCTestCase {
    func testParseMarketStatsSumsReturnedMarkets() throws {
        let json = """
        {
          "rc": 0,
          "data": {
            "diff": [
              { "f104": 1567, "f105": 730, "f106": 47 },
              { "f104": 2008, "f105": 871, "f106": 48 }
            ]
          }
        }
        """.data(using: .utf8)!

        let stats = try MarketSentimentFetcher.parseMarketStatsJSON(json)

        XCTAssertEqual(stats.upCount, 3575)
        XCTAssertEqual(stats.downCount, 1601)
        XCTAssertEqual(stats.flatCount, 95)
    }

    func testParseMarketStatsThrowsWhenDiffMissing() {
        let json = #"{"rc":0,"data":{"total":0}}"#.data(using: .utf8)!

        XCTAssertThrowsError(try MarketSentimentFetcher.parseMarketStatsJSON(json))
    }

    func testParseTotalAmountUsesCompositeFieldInsteadOfFixedIndex() throws {
        let text = """
        v_sh000001="1~上证指数~000001~3000.00~2990.00~3001.00~x~x~x~x~x~x~3000.00/100/12000000000";
        v_sz399001="1~深证成指~399001~9000.00~8900.00~9001.00~x~x~9000.00/200/34000000000";
        """

        let amount = try MarketSentimentFetcher.parseTotalAmount(text)

        XCTAssertEqual(amount, 460, accuracy: 0.0001)
    }

    func testParseTotalAmountThrowsWhenNoAmountFound() {
        XCTAssertThrowsError(try MarketSentimentFetcher.parseTotalAmount("v_sh000001=\"bad\";"))
    }
}
