import 'dart:io';

/// Configures the HTTP proxy used by Dart network requests in this isolate.
/// Each download worker installs its own copy because HttpOverrides are
/// isolate-local.
class AppHttpProxy {
  static String? _address;
  static String? _username;
  static String? _password;

  static ({String user, String password})? credentialsForHost(String host) {
    final address = _address;
    final username = _username;
    if (address == null || username == null) return null;
    final proxyHost = Uri.parse('http://$address').host;
    final requestedHost = Uri.tryParse('http://$host')?.host ?? host;
    if (requestedHost.toLowerCase() != proxyHost.toLowerCase()) return null;
    return (user: username, password: _password ?? '');
  }

  /// Accepts an HTTP proxy as host:port, [IPv6]:port, or http://host:port.
  /// Returns null when the address cannot be used by dart:io's HTTP proxy.
  static String? normalize(String input) {
    final value = input.trim();
    if (value.isEmpty || RegExp(r'\s').hasMatch(value)) return null;
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    return '$host:${uri.port}';
  }

  static void configure(String? address, {String? username, String? password}) {
    _address = address == null ? null : normalize(address);
    _username = _address == null || username == null || username.isEmpty
        ? null
        : username;
    _password = _username == null ? null : password ?? '';
    if (HttpOverrides.current is! _AppHttpOverrides) {
      HttpOverrides.global = _AppHttpOverrides(HttpOverrides.current);
    }
  }
}

class _AppHttpOverrides extends HttpOverrides {
  final HttpOverrides? previous;

  _AppHttpOverrides(this.previous);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        previous?.createHttpClient(context) ?? super.createHttpClient(context);
    client.authenticateProxy = (host, port, scheme, realm) async {
      final address = AppHttpProxy._address;
      final username = AppHttpProxy._username;
      if (address == null || username == null) return false;
      final endpoint = Uri.parse('http://$address');
      if (host.toLowerCase() != endpoint.host.toLowerCase() ||
          port != endpoint.port) {
        return false;
      }
      final credentials = switch (scheme.toLowerCase()) {
        'basic' => HttpClientBasicCredentials(
          username,
          AppHttpProxy._password ?? '',
        ),
        'digest' => HttpClientDigestCredentials(
          username,
          AppHttpProxy._password ?? '',
        ),
        _ => null,
      };
      if (credentials == null) return false;
      client.addProxyCredentials(host, port, realm ?? '', credentials);
      return true;
    };
    return client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    final host = url.host;
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        (InternetAddress.tryParse(host)?.isLoopback ?? false)) {
      return 'DIRECT';
    }
    final address = AppHttpProxy._address;
    if (address != null && (url.scheme == 'http' || url.scheme == 'https')) {
      return 'PROXY $address';
    }
    return previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}
