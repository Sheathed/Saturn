import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saturn/ui/elements.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../../api/definitions.dart';
import '../../ui/home_screen.dart';
import '../platform_manager.dart';
import 'deezer_image_urls.dart';

class DeezerBrowseCategoriesSection extends StatelessWidget {
  final HomePageSection section;
  const DeezerBrowseCategoriesSection(this.section, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cardWidth = math.min(
        120.0,
        math.max(96.0, constraints.maxWidth / 12),
      );
      return SizedBox(
        height: cardWidth + 32,
        child: SilkyListView.separated(
          silkyConfig: silkyHorizontalScrollConfig,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: section.items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final item = section.items[index];
            if (item == null ||
                !item.isPlatformItem('channel') ||
                item.value is! DeezerChannel) {
              return const SizedBox.shrink();
            }
            final channel = item.value as DeezerChannel;
            final image = channel.backgroundImage;
            final imageUrl = image?.imageHash == null
                ? (image?.full ?? '')
                : deezerImageUrl(image?.type, image?.imageHash, '600', '600');
            return SizedBox(
              width: cardWidth,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  final target = channel.target;
                  if (target == null || target.isEmpty) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: FreezerAppBar(channel.title ?? ''),
                        body: HomePageScreen(
                          loadPage: () => PlatformManager.instance
                              .getPlatform(item.platformId ?? 'deezer')
                              .getChannel(target),
                        ),
                      ),
                    ),
                  );
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (imageUrl.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => ColoredBox(
                                  color:
                                      channel.backgroundColor ??
                                      Theme.of(context).colorScheme.surface,
                                ),
                              )
                            else
                              ColoredBox(
                                color:
                                    channel.backgroundColor ??
                                    Theme.of(context).colorScheme.surface,
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      channel.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
