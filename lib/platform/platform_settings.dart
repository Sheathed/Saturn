import 'package:material_ui/material_ui.dart';

abstract class PlatformSetting {
  final String id;
  final String title;
  final String description;
  final IconData icon;

  const PlatformSetting({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
  });
}

class ChoicePlatformOption {
  final String value;
  final String label;
  final String? subtitle;

  const ChoicePlatformOption({
    required this.value,
    required this.label,
    this.subtitle,
  });
}

class ChoicePlatformSetting extends PlatformSetting {
  final String currentValue;
  final List<ChoicePlatformOption> options;
  final Future<void> Function(String) onChanged;

  const ChoicePlatformSetting({
    required super.id,
    required super.title,
    required super.description,
    required super.icon,
    required this.currentValue,
    required this.options,
    required this.onChanged,
  });
}

class BooleanPlatformSetting extends PlatformSetting {
  final bool currentValue;
  final Future<void> Function(bool) onChanged;

  const BooleanPlatformSetting({
    required super.id,
    required super.title,
    required super.description,
    required super.icon,
    required this.currentValue,
    required this.onChanged,
  });
}

class ActionPlatformSetting extends PlatformSetting {
  final String currentValueDisplay;
  final Future<void> Function(BuildContext context) onAction;

  const ActionPlatformSetting({
    required super.id,
    required super.title,
    required super.description,
    required super.icon,
    required this.currentValueDisplay,
    required this.onAction,
  });
}
