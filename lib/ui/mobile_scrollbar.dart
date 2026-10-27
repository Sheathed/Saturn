import 'package:draggable_scrollbar/draggable_scrollbar.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:silky_scroll/silky_scroll.dart';

import 'smooth_scroll_config.dart';

class MobileScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Color backgroundColor;
  final BoxScrollView Function(
    ScrollController controller,
    ScrollPhysics? physics,
  )
  childBuilder;

  const MobileScrollbar({
    required this.controller,
    required this.backgroundColor,
    required this.childBuilder,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (isDesktop) {
      return SilkyScroll.fromConfig(
        config: silkyScrollConfig,
        controller: controller,
        builder: (context, smoothController, physics, _) => childBuilder(
          smoothController,
          physics,
        ),
      );
    }

    return DraggableScrollbar.rrect(
      controller: controller,
      backgroundColor: backgroundColor,
      child: childBuilder(controller, null),
    );
  }
}
