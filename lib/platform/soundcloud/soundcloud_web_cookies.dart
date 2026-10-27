import 'package:webview_all/webview_all.dart';

/// Keeps SoundCloud's WebViews on the same account as its API client.
class SoundCloudWebCookies {
  static Future<void> _pending = Future<void>.value();

  static Future<void> _serialize(Future<void> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.catchError((Object _) {});
    return result;
  }

  static Map<String, String> parse(String input) {
    final value = input.trim().replaceFirst(
      RegExp(r'^Cookie:\s*', caseSensitive: false),
      '',
    );
    if (!value.contains('=')) return {'oauth_token': value};
    final cookies = <String, String>{};
    for (final part in value.split(';')) {
      final separator = part.indexOf('=');
      if (separator < 1) continue;
      final name = part.substring(0, separator).trim();
      final cookieValue = part.substring(separator + 1).trim();
      if (RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) &&
          !cookieValue.contains(RegExp(r'[\r\n]'))) {
        cookies[name] = cookieValue;
      }
    }
    return cookies;
  }

  static Future<String?> readOauthToken({String? excluding}) async {
    if (WebViewPlatform.instance == null) return null;
    final manager = WebViewCookieManager();
    for (final host in ['m.soundcloud.com', 'soundcloud.com']) {
      final cookies = await manager.getCookies(domain: Uri.https(host, '/'));
      for (final cookie in cookies) {
        if (cookie.name == 'oauth_token' &&
            cookie.value.isNotEmpty &&
            cookie.value != excluding) {
          return cookie.value;
        }
      }
    }
    return null;
  }

  static Future<void> install(Map<String, String> cookies) =>
      _serialize(() async {
        if (WebViewPlatform.instance == null || cookies.isEmpty) return;
        final manager = WebViewCookieManager();
        final oauthToken = cookies['oauth_token'];
        if (oauthToken != null) {
          await manager.setCookie(
            WebViewCookie(
              name: 'oauth_token',
              value: oauthToken,
              domain: '.soundcloud.com',
            ),
          );
        }
        for (final entry in cookies.entries) {
          if (entry.key == 'oauth_token') continue;
          try {
            await manager.setCookie(
              WebViewCookie(
                name: entry.key,
                value: entry.value,
                domain: '.soundcloud.com',
              ),
            );
          } catch (_) {
            // A browser cookie may require a host-only or Secure scope that
            // this WebView cookie API cannot express. Keep the OAuth session.
          }
        }
      });

  /// The WebView package only exposes an all-or-nothing cookie clear.
  static Future<void> clear() => _serialize(() async {
    if (WebViewPlatform.instance == null) return;
    await WebViewCookieManager().clearCookies();
  });
}
