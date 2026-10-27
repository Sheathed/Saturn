import 'package:flutter/material.dart' show Axis, Curves;
import 'package:silky_scroll/silky_scroll.dart';

/// Shared scroll tuning for the app's desktop and trackpad scroll views.
const silkyScrollConfig = SilkyScrollConfig(
  silkyScrollDuration: Duration(milliseconds: 320),
  scrollSpeed: 1,
  animationCurve: Curves.easeOutCubic,
  blockWebOverscrollBehaviorX: false,
);

/// Horizontal counterpart for carousels, whose direction must override the
/// vertical default used by the main page scroll views.
const silkyHorizontalScrollConfig = SilkyScrollConfig(
  direction: Axis.horizontal,
  silkyScrollDuration: Duration(milliseconds: 320),
  scrollSpeed: 1,
  animationCurve: Curves.easeOutCubic,
  blockWebOverscrollBehaviorX: false,
);
