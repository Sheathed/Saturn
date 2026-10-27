import 'package:saturn/ui/cached_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saturn/api/definitions.dart';
import 'deezer_image_urls.dart';

class ChannelTile extends StatelessWidget {
  final DeezerChannel channel;
  final VoidCallback? onTap;
  const ChannelTile(this.channel, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool isWhiteBackground =
        channel.backgroundColor?.toARGB32() == 0xFFFFFFFF;
    final hasArtwork =
        channel.logoImage != null ||
        channel.logo != null ||
        channel.backgroundImage != null;
    final imageUrl =
        channel.logoImage?.thumbUrl ??
        channel.logo ??
        (channel.backgroundImage != null
            ? (channel.backgroundImage!.imageHash != null
                ? deezerImageUrl(
                    channel.backgroundImage!.type,
                    channel.backgroundImage!.imageHash,
                    '134',
                    '264',
                    quality: '100',
                  )
                : (channel.backgroundImage!.full ??
                    channel.backgroundImage!.thumb ??
                    ''))
            : '');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Align(
        alignment: Alignment.topLeft,
        widthFactor: 1,
        heightFactor: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.0),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 170,
            height: 85,
            child: ColoredBox(
              color:
                  channel.backgroundColor ??
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              child: InkWell(
                onTap: onTap,
                child: Stack(
                  children: [
                    if (isWhiteBackground && hasArtwork)
                      Positioned.fill(
                        child: CachedImage(
                          url: channel.backgroundImage != null
                              ? (channel.backgroundImage!.imageHash != null
                                  ? deezerImageUrl(
                                      channel.backgroundImage!.type,
                                      channel.backgroundImage!.imageHash,
                                      '134',
                                      '264',
                                      quality: '100',
                                    )
                                  : (channel.backgroundImage!.full ??
                                      channel.backgroundImage!.thumb ??
                                      ''))
                              : imageUrl,
                          fit: BoxFit.cover,
                        ),
                      ),
                    if (!isWhiteBackground && hasArtwork)
                      Positioned(
                        right: -12,
                        bottom: -8,
                        child: Transform.rotate(
                          angle: 0.25,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8.0),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(-2, 2),
                                ),
                              ],
                            ),
                            child: CachedImage(
                              url: imageUrl,
                              width: 64,
                              height: 64,
                              rounded: true,
                            ),
                          ),
                        ),
                      ),
                    if (!isWhiteBackground && channel.title != null)
                      Positioned(
                        left: 12,
                        top: 12,
                        right: hasArtwork ? 56 : 12,
                        child: Text(
                          channel.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16.0,
                            fontWeight: FontWeight.w800,
                            color:
                                channel.backgroundColor != null &&
                                    channel.backgroundColor!.computeLuminance() >
                                        0.5
                                ? Colors.black87
                                : Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SmartTrackListTile extends StatelessWidget {
  final SmartTrackList smartTrackList;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  const SmartTrackListTile(
    this.smartTrackList, {
    super.key,
    this.onHold,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 225.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Stack(
                children: [
                  CachedImage(
                    width: 128,
                    height: 128,
                    url: smartTrackList.cover?.thumb ?? '',
                    rounded: true,
                  ),
                  SizedBox(
                    width: 128.0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 6.0,
                      ),
                      child: Text(
                        smartTrackList.title ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18.0,
                          shadows: [
                            Shadow(
                              offset: Offset(1, 1),
                              blurRadius: 2,
                              color: Colors.black,
                            ),
                          ],
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 2.0),
            SizedBox(
              width: 144.0,
              child: Text(
                smartTrackList.subtitle ?? '',
                maxLines: 3,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.0),
              ),
            ),
            Container(height: 8.0),
          ],
        ),
      ),
    );
  }
}

class FlowTrackListTile extends StatelessWidget {
  final DeezerFlow deezerFlow;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  const FlowTrackListTile(
    this.deezerFlow, {
    super.key,
    this.onHold,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 185,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: CachedImage(
                url: deezerFlow.cover?.thumb ?? '',
                circular: true,
                width: 128,
                height: 128,
              ),
            ),
            Container(height: 2.0),
            SizedBox(
              width: 144.0,
              child: Text(
                deezerFlow.title ?? '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



