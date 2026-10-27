import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../translations.i18n.dart';

/// Opens a WebView either inside its own screen on mobile (Android/iOS)
/// or inside a centered Dialog on desktop platforms (Linux/Windows/macOS).
///
/// Both presentation modes provide an [AppBar] with the [serviceName],
/// a back button, optional actions, and display the WebView within a [SafeArea].
Future<T?> openAppWebView<T>({
  required BuildContext context,
  required String serviceName,
  Widget? child,
  WebViewController? controller,
  List<Widget>? actions,
  Widget? bottomBar,
  bool barrierDismissible = true,
}) async {
  assert(
    child != null || controller != null,
    'Either child or controller must be provided to openAppWebView',
  );

  final webViewWidget = child ?? WebViewWidget(controller: controller!);
  final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  if (isDesktop) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => AppWebViewDialog(
        serviceName: serviceName,
        actions: actions,
        bottomBar: bottomBar,
        child: webViewWidget,
      ),
    );
  } else {
    return Navigator.of(context).push<T>(
      MaterialPageRoute(
        builder: (routeContext) => AppWebViewScreen(
          serviceName: serviceName,
          actions: actions,
          bottomBar: bottomBar,
          child: webViewWidget,
        ),
      ),
    );
  }
}

/// A full-screen view hosting a WebView with an AppBar (service name, back button)
/// and a SafeArea body container.
class AppWebViewScreen extends StatelessWidget {
  const AppWebViewScreen({
    required this.serviceName,
    required this.child,
    this.actions,
    this.bottomBar,
    super.key,
  });

  final String serviceName;
  final Widget child;
  final List<Widget>? actions;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back'.i18n,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          serviceName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: actions,
      ),
      body: SafeArea(
        child: child,
      ),
      bottomNavigationBar: bottomBar,
    );
  }
}

/// A desktop dialog hosting a WebView with an AppBar (service name, back button)
/// and a SafeArea body container.
class AppWebViewDialog extends StatelessWidget {
  const AppWebViewDialog({
    required this.serviceName,
    required this.child,
    this.actions,
    this.bottomBar,
    super.key,
  });

  final String serviceName;
  final Widget child;
  final List<Widget>? actions;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = (size.width * 0.85).clamp(360.0, 920.0).toDouble();
    final height = (size.height * 0.85).clamp(420.0, 780.0).toDouble();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.none,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: height,
        ),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back'.i18n,
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                serviceName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              actions: actions,
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: child,
              ),
            ),
            bottomNavigationBar: bottomBar,
          ),
        ),
      ),
    );
  }
}
