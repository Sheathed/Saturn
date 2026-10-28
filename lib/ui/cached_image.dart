import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator_master/palette_generator_master.dart';
import '../translations.i18n.dart';

ImagesDatabase imagesDatabase = ImagesDatabase();

ImageProvider<Object> imageProviderForSource(String source) {
  final uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return CachedNetworkImageProvider(source);
  }
  if (uri != null && uri.scheme == 'file') {
    return FileImage(File.fromUri(uri));
  }
  return AssetImage(source);
}

class ImagesDatabase {
  static const _paletteSize = Size(64, 64);
  final Map<String, Future<PaletteGeneratorMaster>> _paletteRequests = {};
  /*
  !!! Using the wrappers so i don't have to rewrite most of the code, because of migration to cached network image
  */

  void saveImage(String url) {
    CachedNetworkImageProvider(url);
  }

  Future<PaletteGeneratorMaster> getPaletteGenerator(String url) {
    return _paletteRequests.putIfAbsent(url, () async {
      try {
        final palette = await PaletteGeneratorMaster.fromImageProvider(
          ResizeImage(
            imageProviderForSource(url),
            width: _paletteSize.width.toInt(),
            height: _paletteSize.height.toInt(),
          ),
          size: _paletteSize,
          maximumColorCount: 8,
          generateHarmony: false,
          timeout: const Duration(seconds: 6),
        );
        if (_paletteRequests.length > 256) {
          _paletteRequests.remove(_paletteRequests.keys.first);
        }
        return palette;
      } catch (_) {
        _paletteRequests.remove(url);
        rethrow;
      }
    });
  }

  Future<Color> getPrimaryColor(String url) async {
    PaletteGeneratorMaster paletteGenerator = await getPaletteGenerator(url);
    return paletteGenerator.colors.first;
  }

  Future<bool> isDark(String url) async {
    PaletteGeneratorMaster paletteGenerator = await getPaletteGenerator(url);
    return paletteGenerator.colors.first.computeLuminance() > 0.5
        ? false
        : true;
  }
}

class CachedImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final bool circular;
  final bool fullThumb;
  final bool rounded;
  final BoxFit? fit;

  const CachedImage({
    super.key,
    required this.url,
    this.height,
    this.width,
    this.circular = false,
    this.fullThumb = false,
    this.rounded = false,
    this.fit,
  });

  @override
  _CachedImageState createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  @override
  Widget build(BuildContext context) {
    if (widget.rounded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: CachedImage(
          url: widget.url,
          height: widget.height,
          width: widget.width,
          circular: false,
          rounded: false,
          fullThumb: widget.fullThumb,
        ),
      );
    }

    if (widget.circular) {
      return ClipOval(
        child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: CachedImage(
            url: widget.url,
            height: widget.height,
            width: widget.width,
            circular: false,
            rounded: false,
            fullThumb: widget.fullThumb,
          ),
        ),
      );
    }

    final effectiveWidth = widget.width ?? widget.height;
    final effectiveHeight = widget.height ?? widget.width;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    int? decodeSize(double? logicalSize) {
      if (logicalSize == null || !logicalSize.isFinite || logicalSize <= 0) {
        return null;
      }
      return (logicalSize * devicePixelRatio).round().clamp(1, 4096).toInt();
    }
    final cacheWidth = decodeSize(effectiveWidth);
    final cacheHeight = decodeSize(effectiveHeight);

    final uri = Uri.tryParse(widget.url);
    if (uri?.scheme == 'file') {
      return Image.file(
        File.fromUri(uri!),
        width: effectiveWidth,
        height: effectiveHeight,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        fit: widget.fit ?? BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          'assets/cover_thumb.jpg',
          width: effectiveWidth,
          height: effectiveHeight,
          fit: widget.fit ?? BoxFit.cover,
        ),
      );
    }

    if (uri?.scheme != 'http' && uri?.scheme != 'https') {
      if (widget.url.isEmpty) {
        return Container(
          width: effectiveWidth,
          height: effectiveHeight,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.music_note,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      }
      return Image.asset(
        widget.url,
        width: effectiveWidth,
        height: effectiveHeight,
        fit: widget.fit ?? BoxFit.cover,
      );
    }

    return CachedNetworkImage(
      imageUrl: widget.url,
      width: effectiveWidth,
      height: effectiveHeight,
      memCacheWidth: cacheWidth,
      memCacheHeight: cacheHeight,
      fit: widget.fit ?? BoxFit.cover,
      placeholder: (context, url) {
        if (widget.fullThumb) {
          return Image.asset(
            'assets/cover.jpg',
            width: effectiveWidth,
            height: effectiveHeight,
          );
        }
        return Image.asset(
          'assets/cover_thumb.jpg',
          width: effectiveWidth,
          height: effectiveHeight,
        );
      },
      errorWidget: (context, url, error) => Image.asset(
        'assets/cover_thumb.jpg',
        width: effectiveWidth,
        height: effectiveHeight,
      ),
    );
  }
}

class ZoomableImage extends StatefulWidget {
  final String url;
  final bool rounded;
  final double? width;
  final double? height;
  final bool? enabled;
  final String? caption;
  final BoxFit? fit;
  final bool circular;

  const ZoomableImage({
    super.key,
    required this.url,
    this.rounded = false,
    this.width,
    this.height,
    this.enabled = true,
    this.caption,
    this.fit,
    this.circular = false,
  });

  @override
  _ZoomableImageState createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final TransformationController _transformationController =
      TransformationController();
  bool photoViewOpened = false;
  bool get enabled => widget.enabled ?? true;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onScaleChanged);
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _onScaleChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if (scale < 0.7 && photoViewOpened) {
      photoViewOpened = false;
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget imageContent = Semantics(
      button: enabled,
      label: 'Album art'.i18n,
      child: CachedImage(
        url: widget.url,
        rounded: widget.rounded,
        width: widget.width,
        height: widget.height,
        fullThumb: true,
        fit: widget.fit,
        circular: widget.circular,
      ),
    );

    if (!enabled) {
      return imageContent;
    }

    return Material(
      color: Colors.transparent,
      shape: widget.circular ? const CircleBorder() : null,
      borderRadius: widget.circular
          ? null
          : widget.rounded
          ? BorderRadius.circular(8.0)
          : BorderRadius.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        child: imageContent,
        onTap: () {
          // Reset scale before opening
          _transformationController.value = Matrix4.identity();

          showGeneralDialog(
            context: context,
            useRootNavigator: true,
            barrierDismissible: true,
            barrierLabel: 'Close'.i18n,
            barrierColor: const Color.fromARGB(0x90, 0, 0, 0),
            pageBuilder: (context, a, b) {
              photoViewOpened = true;
              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (photoViewOpened) {
                        Navigator.pop(context);
                        photoViewOpened = false;
                      }
                    },
                    child: InteractiveViewer(
                      minScale: 0.1,
                      maxScale: 8.0,
                      transformationController: _transformationController,
                      child: Center(
                        child: GestureDetector(
                          onTap:
                              () {}, // Consume tap on image so it doesn't close
                          child: CachedImage(
                            url: widget.url,
                            fullThumb: true,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 16.0,
                    right: 16.0,
                    child: SafeArea(
                      child: Material(
                        color: Colors.transparent,
                        child: IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 32,
                          ),
                          tooltip: 'Close'.i18n,
                          onPressed: () {
                            if (photoViewOpened) {
                              Navigator.pop(context);
                              photoViewOpened = false;
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  if (widget.caption != null)
                    Positioned(
                      top: 16.0,
                      left: 64.0,
                      right: 64.0,
                      child: SafeArea(
                        child: Center(
                          child: Material(
                            type: MaterialType.transparency,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(16.0),
                              ),
                              child: Text(
                                widget.caption!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.0,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ).then((_) {
            photoViewOpened = false;
          });
        },
      ),
    );
  }
}
