package dependency
public func one(): Int64 { 1 }
public func two(): Int64 { 2 }
public func three(): Int64 { 3 }
public func four(): Int64 { 4 }
public func five(): Int64 { 5 }
public open class External { public init() {} }
public interface Contract { func required(): Int64 }
