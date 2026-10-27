import 'package:material_ui/material_ui.dart';
import 'cached_image.dart';

class MosaicImage extends StatelessWidget {
  final List<String> urls;
  final List<String?>? captions;
  final double? width;
  final double? height;
  final bool rounded;
  final bool circular;

  final bool zoomOnTap;
  final String? caption;

  const MosaicImage({
    super.key,
    required this.urls,
    this.captions,
    this.width,
    this.height,
    this.rounded = false,
    this.circular = false,
    this.zoomOnTap = false,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    String? captionAt(int index) =>
        captions != null && index < captions!.length ? captions![index] : caption;

    if (urls.isEmpty) {
      return ZoomableImage(
        url: '', // This will trigger the fallback placeholder in CachedImage
        width: width,
        height: height,
        rounded: rounded,
        circular: circular,
        enabled: zoomOnTap,
        caption: captionAt(0),
      );
    }
    
    if (urls.length == 1) {
      return ZoomableImage(
        url: urls.first,
        width: width,
        height: height,
        rounded: rounded,
        circular: circular,
        enabled: zoomOnTap,
        caption: captionAt(0),
      );
    }

    final displayUrls = urls.take(4).toList();
    Widget grid;

    if (displayUrls.length == 2) {
      grid = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ZoomableImage(url: displayUrls[0], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(0))),
          Expanded(child: ZoomableImage(url: displayUrls[1], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(1))),
        ],
      );
    } else if (displayUrls.length == 3) {
      grid = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ZoomableImage(url: displayUrls[0], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(0))),
                Expanded(child: ZoomableImage(url: displayUrls[1], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(1))),
              ],
            ),
          ),
          Expanded(child: ZoomableImage(url: displayUrls[2], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(2))),
        ],
      );
    } else {
      grid = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ZoomableImage(url: displayUrls[0], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(0))),
                Expanded(child: ZoomableImage(url: displayUrls[1], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(1))),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ZoomableImage(url: displayUrls[2], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(2))),
                Expanded(child: ZoomableImage(url: displayUrls[3], width: double.infinity, height: double.infinity, rounded: false, circular: false, fit: BoxFit.cover, enabled: zoomOnTap, caption: captionAt(3))),
              ],
            ),
          ),
        ],
      );
    }

    if (width != null || height != null) {
      grid = SizedBox(
        width: width,
        height: height,
        child: grid,
      );
    }

    if (rounded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: grid,
      );
    }
    
    if (circular) {
      return ClipOval(
        child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: grid,
        ),
      );
    }

    return grid;
  }
}
