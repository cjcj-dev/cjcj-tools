package imported
import dependency.one
public import dependency.two
protected import dependency.three
internal import dependency.four
private import dependency.five
public import dependency.{External as Renamed, Contract}
public func sum(): Int64 { one() + two() + three() + four() + five() }
public interface LocalContract { func required(): Int64 }
internal interface InternalContract { func internalRequirement(): Int64 }
extend Renamed <: LocalContract & InternalContract {
    public func required(): Int64 { 333444 }
    public func notInherited(): Int64 { 222333 }
    public func internalRequirement(): Int64 { 123987 }
}
