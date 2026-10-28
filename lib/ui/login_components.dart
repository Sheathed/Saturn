import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../translations.i18n.dart';

/// A standardized text field for login and authentication tokens across all platforms.
class LoginTextField extends StatefulWidget {
  const LoginTextField({
    required this.controller,
    required this.labelText,
    this.hintText,
    this.prefixIcon,
    this.obscureText = false,
    this.isPassword = false,
    this.showPasteButton = true,
    this.showClearButton = true,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines = 1,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final bool obscureText;
  final bool isPassword;
  final bool showPasteButton;
  final bool showClearButton;
  final bool enabled;
  final int maxLines;
  final int minLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<LoginTextField> createState() => _LoginTextFieldState();
}

class _LoginTextFieldState extends State<LoginTextField> {
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _obscured = widget.isPassword || widget.obscureText;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(LoginTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      widget.controller.text = data.text!.trim();
      widget.onChanged?.call(widget.controller.text);
    }
  }

  void _handleClear() {
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = widget.controller.text.isNotEmpty;

    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
      ),
    );

    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.8),
    );

    final suffixActions = <Widget>[
      if (hasText && widget.showClearButton && widget.enabled)
        IconButton(
          icon: const Icon(Icons.clear, size: 20),
          tooltip: 'Clear'.i18n,
          onPressed: _handleClear,
        ),
      if (widget.showPasteButton && widget.enabled)
        ExcludeFocus(
          child: IconButton(
            icon: const Icon(Icons.paste, size: 20),
            tooltip: 'Paste from clipboard'.i18n,
            onPressed: _handlePaste,
          ),
        ),
      if (widget.isPassword)
        IconButton(
          icon: Icon(
            _obscured ? Icons.visibility : Icons.visibility_off,
            size: 20,
          ),
          tooltip: _obscured ? 'Show password'.i18n : 'Hide password'.i18n,
          onPressed: () {
            setState(() {
              _obscured = !_obscured;
            });
          },
        ),
    ];

    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      maxLines: _obscured ? 1 : widget.maxLines,
      minLines: _obscured ? 1 : widget.minLines,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        prefixIcon: widget.prefixIcon,
        suffixIcon: suffixActions.isNotEmpty
            ? Row(mainAxisSize: MainAxisSize.min, children: suffixActions)
            : null,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.25,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: focusedBorder,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

/// Standardized primary action button for logging in or confirming credentials.
class LoginPrimaryButton extends StatelessWidget {
  const LoginPrimaryButton({
    required this.label,
    required this.onPressed,
    this.icon = Icons.login,
    this.isLoading = false,
    this.height = 48.0,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool isLoading;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: ExcludeFocus(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: isLoading ? null : onPressed,
          icon: isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, size: 20),
          label: Text(
            isLoading ? 'Verifying...'.i18n : label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// Standardized high-emphasis button for launching webview authentication.
class LoginBrowserButton extends StatelessWidget {
  const LoginBrowserButton({
    required this.label,
    required this.onPressed,
    this.icon = Icons.open_in_browser,
    this.isLoading = false,
    this.height = 48.0,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool isLoading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
            width: 1.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: theme.colorScheme.primary,
                ),
              )
            : Icon(icon, size: 22, color: theme.colorScheme.primary),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Standardized secondary action button.
class LoginSecondaryButton extends StatelessWidget {
  const LoginSecondaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 44.0,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: icon != null
          ? OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onPressed,
              icon: Icon(icon, size: 18),
              label: Text(label),
            )
          : TextButton(
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onPressed,
              child: Text(label),
            ),
    );
  }
}

/// Standardized error banner across all login screens and widgets.
class LoginErrorBanner extends StatelessWidget {
  const LoginErrorBanner({required this.message, this.onDismiss, super.key});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
      decoration: BoxDecoration(
        color: colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12.0),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: Icon(
              Icons.error_outline,
              color: colorScheme.error,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: colorScheme.error,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, size: 16, color: colorScheme.error),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// Standardized collapsible help section for instructions on obtaining tokens.
class LoginHelpSection extends StatefulWidget {
  const LoginHelpSection({
    required this.title,
    required this.content,
    this.initialExpanded = false,
    super.key,
  });

  final String title;
  final Widget content;
  final bool initialExpanded;

  @override
  State<LoginHelpSection> createState() => _LoginHelpSectionState();
}

class _LoginHelpSectionState extends State<LoginHelpSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initialExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.help_outline,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.25),
              ),
            ),
            child: widget.content,
          ),
        ],
      ],
    );
  }
}

/// Standardized divider with an "OR" label between browser and token sign in.
class LoginDivider extends StatelessWidget {
  const LoginDivider({this.label = 'OR', super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Text(
              label.i18n,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
          ),
        ],
      ),
    );
  }
}
