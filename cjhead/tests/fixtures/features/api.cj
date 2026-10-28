// File documentation.
package features
public interface Marker {}
sealed interface Restricted { func call(): Int64 }
public class Primary {
    public Primary(public let value: Int64) {}
}
public class Generic<T> where T <: Marker {
    public init() {}
    public func identity(value: T): T { value }
}
public func identity<T>(value: T): T where T <: Marker { value }
extend<T> Generic<T> where T <: Marker {
    public func bounded(value: T): T { value }
}
public class Ordinary {
    public init() {}
    protected func unexported(): Int64 { 678678 }
}
@When[os == "Windows"]
public func windowsOnly(): Int64 { 789789 }
@When[os != "Windows"]
public func unixOnly(): Int64 { 789789 }

public interface Extra {}
public class Carrier<T> {
    public init() {}
}
extend<T> Carrier<T> where T <: Marker & Extra {
    public func extraBound(value: T): T { value }
}
