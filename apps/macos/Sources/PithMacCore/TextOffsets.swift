import Foundation

public enum TextOffsets {
    public static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    public static func split(_ text: String, atScalar offset: Int) -> (before: String, after: String) {
        let index = scalarIndex(offset, in: text)
        return (String(text.unicodeScalars[..<index]), String(text.unicodeScalars[index...]))
    }

    public static func utf16(fromScalar offset: Int, in text: String) -> Int {
        let index = scalarIndex(offset, in: text)
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    public static func scalar(fromUTF16 offset: Int, in text: String) -> Int {
        let utf16 = text.utf16
        var units = max(0, min(offset, utf16.count))
        while units > 0,
              utf16.index(utf16.startIndex, offsetBy: units).samePosition(in: text.unicodeScalars) == nil {
            units -= 1
        }
        let index = utf16.index(utf16.startIndex, offsetBy: units)
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    private static func scalarIndex(_ offset: Int, in text: String) -> String.Index {
        let scalars = text.unicodeScalars
        let clamped = max(0, min(offset, scalars.count))
        return scalars.index(scalars.startIndex, offsetBy: clamped)
    }
}
