import 'type_alias.dart';

// Path constants ported from ytmusicapi.navigation.
const content = ['contents', 0];
const runText = ['runs', 0, 'text'];
const tabContent = ['tabs', 0, 'tabRenderer', 'content'];
const tab1Content = ['tabs', 1, 'tabRenderer', 'content'];
const tab2Content = ['tabs', 2, 'tabRenderer', 'content'];
const twoColumnRenderer = ['contents', 'twoColumnBrowseResultsRenderer'];
const singleColumn = ['contents', 'singleColumnBrowseResultsRenderer'];
const singleColumnTab = [...singleColumn, ...tabContent];
const section = ['sectionListRenderer'];
const sectionList = [...section, 'contents'];
const sectionListItem = [...section, ...content];
const itemSection = ['itemSectionRenderer', ...content];
const musicShelf = ['musicShelfRenderer'];
const grid = ['gridRenderer'];
const gridItems = [...grid, 'items'];
const responsiveHeader = ['musicResponsiveHeaderRenderer'];
const header = ['header'];
const headerDetail = [...header, 'musicDetailHeaderRenderer'];
const menu = ['menu', 'menuRenderer'];
const menuItems = [...menu, 'items'];
const menuTopLevelButtons = [...menu, 'topLevelButtons'];
const menuService = ['menuServiceItemRenderer', 'serviceEndpoint'];
const overlayRenderer = [
  'musicItemThumbnailOverlayRenderer',
  'content',
  'musicPlayButtonRenderer',
];
const queueVideoId = ['queueAddEndpoint', 'queueTarget', 'videoId'];
const navigationBrowse = ['navigationEndpoint', 'browseEndpoint'];
const navigationBrowseId = [...navigationBrowse, 'browseId'];
const pageType = [
  'browseEndpointContextSupportedConfigs',
  'browseEndpointContextMusicConfig',
  'pageType',
];
const menuLikeStatus = [
  'menu',
  'menuRenderer',
  'topLevelButtons',
  0,
  'likeButtonRenderer',
  'likeStatus',
];
const watchVideoId = ['watchEndpoint', 'videoId'];
const navigationVideoId = ['navigationEndpoint', ...watchVideoId];
const playlistId = ['playlistId'];
const watchPlaylistId = ['watchEndpoint', ...playlistId];
const navigationWatchPlaylistId = [
  'navigationEndpoint',
  'watchPlaylistEndpoint',
  ...playlistId,
];
const navigationPlaylistId = ['navigationEndpoint', ...watchPlaylistId];
const watchPlaylistMenuId = ['watchPlaylistEndpoint', ...playlistId];
const playButton = [
  'overlay',
  'musicItemThumbnailOverlayRenderer',
  'content',
  'musicPlayButtonRenderer',
];
const playNavigationEndpoint = [...playButton, 'playNavigationEndpoint'];
const iconType = ['icon', 'iconType'];
const badgeLabel = [
  'badges',
  0,
  'musicInlineBadgeRenderer',
  'accessibilityData',
  'accessibilityData',
  'label',
];
const watchEndpointVideoType = [
  'watchEndpoint',
  'watchEndpointMusicSupportedConfigs',
  'watchEndpointMusicConfig',
  'musicVideoType',
];
const title = ['title', 'runs', 0];
const titleText = ['title', ...runText];
const textRuns = ['text', 'runs'];
const textRun = [...textRuns, 0];
const textRunText = [...textRun, 'text'];
const subtitle = ['subtitle', ...runText];
const subtitleRuns = ['subtitle', 'runs'];
const subtitle2 = [...subtitleRuns, 2, 'text'];
const subtitle3 = [...subtitleRuns, 4, 'text'];
const subtitleBadgeLabel = [
  'subtitleBadges',
  0,
  'musicInlineBadgeRenderer',
  'accessibilityData',
  'accessibilityData',
  'label',
];
const thumbnail = ['thumbnail', 'thumbnails'];
const thumbnailCropped = [
  'thumbnail',
  'croppedSquareThumbnailRenderer',
  ...thumbnail,
];
const thumbnails = ['thumbnail', 'musicThumbnailRenderer', ...thumbnail];
const thumbnailRenderer = [
  'thumbnailRenderer',
  'musicThumbnailRenderer',
  ...thumbnail,
];
const thumbnailOverlayNavigation = [
  'thumbnailOverlay',
  ...overlayRenderer,
  'playNavigationEndpoint',
];
const thumbnailOverlay = [
  ...thumbnailOverlayNavigation,
  ...watchPlaylistMenuId,
];
const descriptionShelf = [
  'musicDescriptionShelfRenderer',
  'description',
  'runs',
  0,
  'text',
];
const feedbackToken = ['feedbackEndpoint', 'feedbackToken'];
const categoryTitle = [
  'musicNavigationButtonRenderer',
  'buttonText',
  ...runText,
];
const categoryParams = [
  'musicNavigationButtonRenderer',
  'clickCommand',
  'browseEndpoint',
  'params',
];
const tasteProfileItems = ['contents', 'tastebuilderRenderer', 'contents'];
const tasteProfileArtist = ['title', 'runs'];
const sectionListContinuation = [
  'continuationContents',
  'sectionListContinuation',
];
const menuPlaylistId = [
  ...menuItems,
  0,
  'menuNavigationItemRenderer',
  ...navigationWatchPlaylistId,
];
const multiSelect = ['musicMultiSelectMenuItemRenderer'];
const editablePlaylistDetailHeader = [
  'musicEditablePlaylistDetailHeaderRenderer',
];
const headerEditableDetail = [...header, ...editablePlaylistDetailHeader];
const headerSide = [...header, 'musicSideAlignedItemRenderer'];
const headerMusicVisual = [...header, 'musicVisualHeaderRenderer'];
const description = ['description', ...runText];
const descriptionRunList = ['description', 'runs'];
const carousel = ['musicCarouselShelfRenderer'];
const immersiveCarousel = ['musicImmersiveCarouselShelfRenderer'];
const carouselContents = [...carousel, 'contents'];
const carouselTitle = [
  ...header,
  'musicCarouselShelfBasicHeaderRenderer',
  ...title,
];
const carouselStrapline = [
  ...header,
  'musicCarouselShelfBasicHeaderRenderer',
  'strapline',
  'runs',
  0,
];
const cardShelfTitle = [
  ...header,
  'musicCardShelfHeaderBasicRenderer',
  ...titleText,
];
const frameworkMutations = [
  'frameworkUpdates',
  'entityBatchUpdate',
  'mutations',
];
const timestampedLyrics = [
  'contents',
  'elementRenderer',
  'newElement',
  'type',
  'componentType',
  'model',
  'timedLyricsModel',
  'lyricsData',
];
const creditsSections = [
  'onResponseReceivedActions',
  0,
  'openPopupAction',
  'popup',
  'dismissableDialogRenderer',
  'sections',
];
const responsiveItem = 'musicResponsiveListItemRenderer';
const twoRowItem = 'musicTwoRowItemRenderer';
const multiRowItem = 'musicMultiRowListItemRenderer';
const menuNavigationItem = 'menuNavigationItemRenderer';
const toggleMenu = 'toggleMenuServiceItemRenderer';
const engagementBar = [
  'engagementBar',
  'engagementBarViewModel',
  'actions',
  0,
  'votingViewModel',
  'initialState',
];

/// Safely follows the same path semantics as ytmusicapi.navigation.nav.
dynamic nav(dynamic root, List<Object> path, {bool absent = false}) {
  if (root == null) {
    return null;
  }
  dynamic current = root;
  for (final key in path) {
    if (current is Map && current.containsKey(key)) {
      current = current[key];
    } else if (current is List &&
        key is int &&
        current.isNotEmpty &&
        key >= -current.length &&
        key < current.length) {
      current = current[key < 0 ? current.length + key : key];
    } else if (absent) {
      return null;
    } else {
      throw StateError('Unable to find "$key" using path $path');
    }
  }
  return current;
}

dynamic findObjectByKey(
  List<dynamic> values,
  String key, {
  String? nested,
  bool returnValue = false,
}) {
  for (final value in values) {
    final item = asJsonDict(
      nested == null ? value : asJsonDict(value)?[nested],
    );
    if (item != null && item.containsKey(key)) {
      return returnValue ? item[key] : item;
    }
  }
  return null;
}

List<JsonDict> findObjectsByKey(
  List<dynamic> values,
  String key, {
  String? nested,
}) {
  final found = <JsonDict>[];
  for (final value in values) {
    final item = nested == null
        ? asJsonDict(value)
        : asJsonDict(asJsonDict(value)?[nested]);
    if (item != null && item.containsKey(key)) {
      found.add(item);
    }
  }
  return found;
}
