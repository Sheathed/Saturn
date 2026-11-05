import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' show Axis, Curves, TargetPlatform;
import 'package:silky_scroll/silky_scroll.dart';

const _verticalSilkyScrollConfig = SilkyScrollConfig(
  silkyScrollDuration: Duration(milliseconds: 320),
  scrollSpeed: 1,
  animationCurve: Curves.easeOutCubic,
  blockWebOverscrollBehaviorX: false,
);

const _horizontalSilkyScrollConfig = SilkyScrollConfig(
  direction: Axis.horizontal,
  silkyScrollDuration: Duration(milliseconds: 320),
  scrollSpeed: 1,
  animationCurve: Curves.easeOutCubic,
  blockWebOverscrollBehaviorX: false,
);

bool get _isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Shared scroll tuning for the app's desktop and trackpad scroll views.
///
/// SilkyScroll's delayed edge lock can leave its temporary
/// NeverScrollableScrollPhysics active after touch interactions on mobile.
/// Keep normal Flutter touch scrolling there by making that lock immediate to
/// release, while preserving the tuned desktop behavior.
SilkyScrollConfig get silkyScrollConfig => _isTouchPlatform
    ? _verticalSilkyScrollConfig.copyWith(edgeLockingDelay: Duration.zero)
    : _verticalSilkyScrollConfig;

/// Horizontal counterpart for carousels, whose direction must override the
/// vertical default used by the main page scroll views.
SilkyScrollConfig get silkyHorizontalScrollConfig => _isTouchPlatform
    ? _horizontalSilkyScrollConfig.copyWith(edgeLockingDelay: Duration.zero)
    : _horizontalSilkyScrollConfig;
