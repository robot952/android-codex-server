import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps the top of a visible row still while a bottom-origin transcript grows.
/// Corrections happen during layout, before paint, rather than jumping back in
/// a post-frame callback. Only already materialized children are inspected.
class ReadingAnchorSliverList extends SliverList {
  const ReadingAnchorSliverList({
    super.key,
    required super.delegate,
    required this.preserveReadingPosition,
  });

  final bool Function() preserveReadingPosition;

  @override
  SliverMultiBoxAdaptorElement createElement() =>
      SliverMultiBoxAdaptorElement(this);

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _ReadingAnchorRenderSliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
        preserveReadingPosition: preserveReadingPosition,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    (renderObject as _ReadingAnchorRenderSliverList).preserveReadingPosition =
        preserveReadingPosition;
  }
}

class _ReadingAnchorRenderSliverList extends RenderSliverList {
  _ReadingAnchorRenderSliverList({
    required super.childManager,
    required this.preserveReadingPosition,
  });

  bool Function() preserveReadingPosition;
  RenderBox? _anchor;
  double _anchorEnd = 0;
  double _viewportExtent = 0;
  double _precedingExtent = 0;
  double _appliedCorrection = 0;
  bool _correcting = false;
  bool _preserving = false;
  bool _needsOriginRebase = false;
  final Map<RenderBox, double> _previousOffsets = {};

  @override
  void collectGarbage(int leadingGarbage, int trailingGarbage) {
    final anchor = _anchor;
    if (_preserving && !_correcting && anchor != null) {
      var anchorIndex = 0;
      var child = firstChild;
      while (child != null && child != anchor) {
        anchorIndex++;
        child = childAfter(child);
      }
      if (child == anchor && anchorIndex < leadingGarbage) {
        final offset = childScrollOffset(anchor);
        if (offset != null &&
            (offset + paintExtentOf(anchor) - _anchorEnd).abs() > 0.01) {
          leadingGarbage = anchorIndex;
        }
      }
      if (child == anchor && anchorIndex >= leadingGarbage) {
        // A large streamed chunk can move the previous reading row outside
        // the new cache window. Measure it before SliverList discards it.
        // Walk only the existing contiguous children, never materialize the
        // rest of the history just to estimate its height.
        var offset = firstChild == null ? null : childScrollOffset(firstChild!);
        var previousIndex = firstChild == null ? -1 : indexOf(firstChild!) - 1;
        for (
          var current = firstChild;
          current != null && offset != null;
          current = childAfter(current)
        ) {
          if (indexOf(current) != previousIndex + 1) break;
          current.layout(constraints.asBoxConstraints(), parentUsesSize: true);
          final data = current.parentData! as SliverMultiBoxAdaptorParentData;
          data.layoutOffset = offset;
          offset += paintExtentOf(current);
          previousIndex = indexOf(current);
          if (current == anchor) {
            final afterAnchor = childCount - anchorIndex - 1;
            if (trailingGarbage > afterAnchor) trailingGarbage = afterAnchor;
            break;
          }
        }
      }
    }
    super.collectGarbage(leadingGarbage, trailingGarbage);
  }

  @override
  void performLayout() {
    final preserve =
        constraints.growthDirection == GrowthDirection.reverse &&
        preserveReadingPosition();
    final returningToBottom = _preserving && !preserve;
    _preserving = preserve;
    if (!preserve) {
      _anchor = null;
      _appliedCorrection = 0;
      if (returningToBottom && _needsOriginRebase) {
        // Rows appended outside the lazy window intentionally retain their
        // reading coordinates. Rebase from item zero when following output
        // again instead of letting dead reckoning push the viewport away.
        super.collectGarbage(childCount, 0);
        _previousOffsets.clear();
        _needsOriginRebase = false;
      }
    } else {
      // Keyed rows can move by an entire page when new output is appended.
      // Keep their known offsets instead of replacing the old indices with
      // unrelated new rows. SliverList fills only the visible/cache window.
      final first = firstChild;
      if (first != null && childScrollOffset(first) == null) {
        final previous = _previousOffsets[first];
        if (previous != null) {
          (first.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
              previous;
          _needsOriginRebase = true;
        }
      }
    }
    final anchor = _anchor;
    super.performLayout();
    final nativeCorrection = geometry?.scrollOffsetCorrection;
    if (nativeCorrection != null) {
      _appliedCorrection += nativeCorrection;
      return;
    }

    if (preserve && anchor != null && anchor.parent == this && anchor.hasSize) {
      final offset = childScrollOffset(anchor);
      if (offset != null) {
        final correction =
            offset +
            paintExtentOf(anchor) -
            _anchorEnd -
            (constraints.viewportMainAxisExtent - _viewportExtent) +
            (constraints.precedingScrollExtent - _precedingExtent) -
            _appliedCorrection;
        if (!_correcting && correction.abs() > 0.01) {
          // The viewport applies this with the reverse growth direction's sign
          // and lays out again in the same frame. Never interrupt a drag or
          // fling with jumpTo, and never depend on estimated total list height.
          geometry = SliverGeometry(scrollOffsetCorrection: correction);
          _correcting = true;
          _appliedCorrection += correction;
          return;
        }
      }
    }

    _correcting = false;
    _appliedCorrection = 0;
    _anchor = null;
    _viewportExtent = constraints.viewportMainAxisExtent;
    _precedingExtent = constraints.precedingScrollExtent;
    _previousOffsets.clear();
    if (firstChild != null && indexOf(firstChild!) == 0) {
      _needsOriginRebase = false;
    }
    final visibleStart = constraints.scrollOffset;
    final visibleEnd = visibleStart + constraints.remainingPaintExtent;
    // In reverse growth order the last visible child is at the screen top.
    // Its trailing layout edge is the visual top, including for a long message
    // whose first line is outside the viewport.
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final offset = childScrollOffset(child);
      if (offset == null || !child.hasSize) continue;
      _previousOffsets[child] = offset;
      final end = offset + paintExtentOf(child);
      if (offset < visibleEnd && end > visibleStart) {
        _anchor = child;
        _anchorEnd = end;
      }
    }
  }
}
