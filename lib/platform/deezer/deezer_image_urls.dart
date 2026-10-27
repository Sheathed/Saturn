/// Builds resized image URLs for image hashes returned by Deezer.
String deezerImageUrl(
  String? type,
  String? imageHash,
  String height,
  String width, {
  String quality = '80',
}) =>
    'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-000000-$quality-0-0.jpg';

String deezerFlowImageUrl(
  String? type,
  String? imageHash,
  String height,
  String width, {
  String quality = '80',
}) =>
    'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-000000-$quality-0-0.png';

String deezerLogoUrl(
  String? type,
  String? imageHash,
  String height, {
  String width = '0',
  String quality = '100',
}) =>
    'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-none-$quality-0-0.png';
