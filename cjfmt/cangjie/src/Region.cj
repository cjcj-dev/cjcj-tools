// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjfmt_core

import cjcj::ast.{Node, Decl, ASTKind}
import cjcj::basic.{Position, SourceManager}

public func FormattingBegin(node: Node): Position {
    var begin = node.begin
    if (let Some(decl) <- (node as Decl)) {
        for (annotation in decl.annotations) {
            if (annotation.begin < begin) { begin = annotation.begin }
        }
        for (modifier in decl.modifiers) {
            if (modifier.begin < begin) { begin = modifier.begin }
        }
    }
    return begin
}

// Port of T271 RegionFormattingTracker. Positions and node kinds are the
// compiler's Cangjie types, not an independently decoded AST representation.
public class RegionFormattingTracker {
    public var shouldFormatBegin: Position
    public var shouldFormatEnd: Position
    private var actuallyFormattedStart: Option<Position> = None
    private var actuallyFormattedEnd: Option<Position> = None
    private var outsideBegin: Option<Position> = None
    private var insideBegin: Option<Position> = None
    private var outsideEnd: Option<Position> = None
    private var insideEnd: Option<Position> = None

    public init(startLine: Int64, endLine: Int64) {
        if (startLine < 1 || endLine < startLine) { throw IllegalArgumentException("Invalid format region") }
        shouldFormatBegin = Position(startLine, 1)
        shouldFormatEnd = Position(endLine, 2147483647)
    }

    private func ProcessPotentialCuttingPoint(pos: Position): Unit {
        if (pos < shouldFormatBegin) {
            if (let Some(old) <- outsideBegin) {
                if (old < pos) { outsideBegin = pos }
            } else { outsideBegin = pos }
        }
        if (pos >= shouldFormatBegin && pos < shouldFormatEnd) {
            if (let Some(old) <- insideBegin) {
                if (old > pos) { insideBegin = pos }
            } else { insideBegin = pos }
        }
        if (pos > shouldFormatBegin && pos <= shouldFormatEnd) {
            if (let Some(old) <- insideEnd) {
                if (old < pos) { insideEnd = pos }
            } else { insideEnd = pos }
        }
        if (pos > shouldFormatEnd) {
            if (let Some(old) <- outsideEnd) {
                if (old > pos) { outsideEnd = pos }
            } else { outsideEnd = pos }
        }
    }

    public func ShouldFormat(node: Node): Bool {
        let begin = FormattingBegin(node)
        let selected = !(shouldFormatBegin > node.end || shouldFormatEnd < begin)
        if (selected && (node.astKind == ASTKind.BINARY_EXPR || node.astKind == ASTKind.MACRO_EXPAND_DECL)) {
            if (begin < shouldFormatBegin) { shouldFormatBegin = begin }
            if (node.end > shouldFormatEnd) { shouldFormatEnd = node.end }
        }
        return selected
    }

    public func IsInsideFormattedNode(node: Node): Bool {
        if (let Some(begin) <- actuallyFormattedStart) {
            if (let Some(end) <- actuallyFormattedEnd) {
                return FormattingBegin(node) >= begin && node.end <= end
            }
        }
        return false
    }

    public func ProcessNodeFormatted(node: Node): Unit {
        let begin = FormattingBegin(node)
        if (let Some(old) <- actuallyFormattedStart) {
            if (old > begin) { actuallyFormattedStart = begin }
        } else { actuallyFormattedStart = begin }
        if (let Some(old) <- actuallyFormattedEnd) {
            if (old < node.end) { actuallyFormattedEnd = node.end }
        } else { actuallyFormattedEnd = node.end }
        ProcessPotentialCuttingPoint(begin)
        ProcessPotentialCuttingPoint(node.end)
    }

    public func GetPreciseFragmentBounds(sm: SourceManager): Option<(Position, Position)> {
        var begin = actuallyFormattedStart
        if (let Some(point) <- outsideBegin) { begin = point }
        if (let Some(point) <- insideBegin) {
            let prefix = sm.GetContentBetween(Position(point.fileID, shouldFormatBegin.line, shouldFormatBegin.column), point)
            var whitespace = true
            for (byte in prefix.toArray()) {
                if (byte != 32 && byte != 9 && byte != 10 && byte != 13 && byte != 11 && byte != 12) { whitespace = false }
            }
            if (whitespace) { begin = point }
        }
        var end = actuallyFormattedEnd
        if (let Some(point) <- outsideEnd) { end = point }
        if (let Some(point) <- insideEnd) { end = point }
        if (let Some(b) <- begin) {
            if (let Some(e) <- end) { return (b, e) }
        }
        return None
    }
}
