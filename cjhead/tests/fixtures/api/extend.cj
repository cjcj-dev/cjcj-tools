package api
extend Base {
    public func extra(): Int64 { 654321 }
    protected func inheritedExtra(): Int64 { 777888 }
    private func hiddenExtra(): Int64 { 7654321 }
}
