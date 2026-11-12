import Foundation

extension Array {
    /// 越界返回 nil，避免散落的 indices.contains 判断
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
