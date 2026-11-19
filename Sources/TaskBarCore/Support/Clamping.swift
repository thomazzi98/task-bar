extension Comparable {
    /// The value limited to `range`: the lower bound below it, the upper bound above it.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
