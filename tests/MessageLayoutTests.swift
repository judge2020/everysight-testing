import Foundation

@main
struct MessageLayoutTests {
    static func main() {
        precondition(DiscordMessage(["id": "123"]) == nil)
        let messageID = String(UInt64.max - 1), userID = String(UInt64.max - 2)
        let message = DiscordMessage(["id": messageID, "userID": userID, "author": "Friend", "content": "Hi", "timestamp": NSNumber(value: 1234567890123), "edited": true])!
        precondition(message.id == messageID && message.userID == userID)
        precondition(message.edited && message.timestamp == 1234567890123)
        precondition(MessageLayout.pages("one\r\ntwo\rthree\tfour").flatMap { $0 } == ["one", "two", "three    four"])
        precondition(MessageLayout.pages("a\n\nb").flatMap { $0 } == ["a", "", "b"])
        precondition(MessageLayout.pages(String(repeating: "x", count: 39)).flatMap { $0 } == [String(repeating: "x", count: 38), "x"])
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        precondition(MessageLayout.pages(emoji).flatMap { $0 }.joined() == emoji)
        precondition(MessageLayout.pages(emoji).flatMap { $0 }.map(\.count) == [38, 2])
        precondition(MessageLayout.pages("one two three", columns: 7, rows: 2) == [["one two", "three"]])
        precondition(MessageLayout.pages("1\n2\n3\n4\n5\n6") == [["1", "2", "3", "4", "5"], ["6"]])
        for length in [0, 1, 37, 38, 39, 190, 191, 2000] {
            let text = String(repeating: "é", count: length)
            let pages = MessageLayout.pages(text)
            precondition(!pages.isEmpty && pages.allSatisfy { $0.count <= 5 && $0.allSatisfy { $0.count <= 38 } })
            precondition(pages.flatMap { $0 }.joined() == text)
        }
        print("Message parsing and pagination tests passed")
    }
}
