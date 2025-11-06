import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart' as ft;

/// Cross-platform toast wrapper
/// Uses native toasts on mobile (Android/iOS) and FToast on desktop
class Fluttertoast {
  static ft.FToast? _fToast;
  static BuildContext? _context;

  /// Initialize FToast for desktop platforms
  /// Call this once in your app, typically in a StatefulWidget's initState
  static void init(BuildContext context) {
    _context = context;
    if (_isDesktop()) {
      _fToast = ft.FToast();
      _fToast!.init(context);
    }
  }

  /// Check if running on desktop platform
  static bool _isDesktop() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  /// Show a toast message
  /// On mobile: uses native toast
  /// On desktop: uses FToast with custom widget
  static Future<bool?> showToast({
    required String msg,
    ft.Toast? toastLength,
    ft.ToastGravity? gravity,
    Color? backgroundColor,
    Color? textColor,
    double? fontSize,
    int? timeInSecForIosWeb,
  }) async {
    if (_isDesktop()) {
      // Use FToast for desktop
      if (_fToast == null && _context != null) {
        init(_context!);
      }

      if (_fToast != null) {
        // Create custom toast widget
        Widget toast = Container(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25.0),
            color: backgroundColor ?? Colors.grey[800],
          ),
          child: Text(
            msg,
            style: TextStyle(
              color: textColor ?? Colors.white,
              fontSize: fontSize ?? 16.0,
            ),
          ),
        );

        // Determine position based on gravity
        ft.ToastGravity toastGravity = gravity ?? ft.ToastGravity.BOTTOM;
        
        // Determine duration
        Duration duration;
        if (toastLength == ft.Toast.LENGTH_LONG) {
          duration = const Duration(seconds: 5);
        } else {
          duration = const Duration(seconds: 2);
        }

        // Show toast with appropriate gravity
        switch (toastGravity) {
          case ft.ToastGravity.TOP:
            _fToast!.showToast(
              child: toast,
              toastDuration: duration,
              gravity: ft.ToastGravity.TOP,
            );
            break;
          case ft.ToastGravity.CENTER:
            _fToast!.showToast(
              child: toast,
              toastDuration: duration,
              gravity: ft.ToastGravity.CENTER,
            );
            break;
          case ft.ToastGravity.BOTTOM:
          default:
            _fToast!.showToast(
              child: toast,
              toastDuration: duration,
              gravity: ft.ToastGravity.BOTTOM,
            );
            break;
        }

        return true;
      }
      return false;
    } else {
      // Use native toast for mobile
      return ft.Fluttertoast.showToast(
        msg: msg,
        toastLength: toastLength ?? ft.Toast.LENGTH_SHORT,
        gravity: gravity ?? ft.ToastGravity.BOTTOM,
        backgroundColor: backgroundColor,
        textColor: textColor,
        fontSize: fontSize ?? 16.0,
        timeInSecForIosWeb: timeInSecForIosWeb ?? 1,
      );
    }
  }

  /// Cancel all toasts
  static Future<bool?> cancel() async {
    if (_isDesktop()) {
      _fToast?.removeQueuedCustomToasts();
      return true;
    } else {
      return ft.Fluttertoast.cancel();
    }
  }
}

// Re-export enums for convenience
typedef Toast = ft.Toast;
typedef ToastGravity = ft.ToastGravity;
