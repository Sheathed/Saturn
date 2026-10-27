import 'package:flutter/services.dart' show appFlavor;

// Keep builds without a native flavor consistent with Android's product flavor.
const appBuildFlavor =
    appFlavor ??
    String.fromEnvironment('SATURN_FLAVOR', defaultValue: 'stable');

String get appTitle {
  switch (appBuildFlavor) {
    case 'canary':
      return 'Saturn Canary';
    case 'dev':
      return 'Saturn Dev';
    default:
      return 'Saturn';
  }
}
