package api
/** Open base documentation. */
public open class Base {
    public init() {}
    public let number: Int64 = 23
    protected let inherited: Int64 = 42
    private let secret: Int64 = 17
    public func visible(): Int64 { 1234567 }
    protected func inheritedCall(): Int64 { 567891 }
    private func hidden(): Int64 { 7654321 }
    public prop size: Int64 { get() { 11 } }
}
sealed abstract class Closed {
    protected func closedSecret(): Int64 { 123 }
    public func visibleClosed(): Int64 { 55 }
}
public class Box<T> {
    public let item: T
    public init(item: T) { this.item = item }
    public func get(): T { item }
}
public struct Pair {
    public let value: Int64
    public init(value: Int64) { this.value = value }
    private func hiddenPair(): Int64 { 7654321 }
}
public enum Choice {
    First | Second(Int64)
    public func code(): Int64 { 111222 }
    private func hiddenChoice(): Int64 { 7654321 }
}
public interface API {
    prop count: Int64
    func call(): Int64
    func fallback(): Int64 { 778899 }
}
public type Alias = Base
public let constant: Int64 = 77
internal class InternalType {}
private class PrivateType {}
extend PrivateType {
    public func privateExtension(): Int64 { 1 }
}
