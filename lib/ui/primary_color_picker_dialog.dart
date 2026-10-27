import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../translations.i18n.dart';

class PrimaryColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorSelected;

  const PrimaryColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.onColorSelected,
  });

  static const List<Color> presetColors = [
    ...Colors.primaries,
    Color(0xFFECA704),
    Color(0xFFBE3266),
    Color(0xFF4B2E7E),
    Color(0xFF384697),
    Color(0xFF0880B5),
    Color(0xFF009A85),
    Color(0xFF2BA766),
    Color(0xFFA259FF), // Electric Violet
    Color(0xFFFF6584), // Coral Rose
  ];

  @override
  State<PrimaryColorPickerDialog> createState() =>
      _PrimaryColorPickerDialogState();
}

class _PrimaryColorPickerDialogState extends State<PrimaryColorPickerDialog> {
  late Color _currentColor;
  late HSVColor _hsv;
  late TextEditingController _hexController;
  bool _updatingFromHex = false;

  @override
  void initState() {
    super.initState();
    _currentColor = widget.initialColor;
    _hsv = HSVColor.fromColor(_currentColor);
    _hexController = TextEditingController(text: _formatHex(_currentColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _formatHex(Color c) {
    return c
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2)
        .toUpperCase();
  }

  void _updateColorFromHsv(HSVColor newHsv) {
    setState(() {
      _hsv = newHsv;
      _currentColor = newHsv.toColor();
      if (!_updatingFromHex) {
        _hexController.text = _formatHex(_currentColor);
      }
    });
  }

  void _onColorChanged(Color newColor) {
    setState(() {
      _currentColor = newColor;
      _hsv = HSVColor.fromColor(newColor);
      if (!_updatingFromHex) {
        _hexController.text = _formatHex(newColor);
      }
    });
  }

  void _onHexSubmitted(String hex) {
    String clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final val = int.tryParse('FF$clean', radix: 16);
      if (val != null) {
        _updatingFromHex = true;
        _onColorChanged(Color(val));
        _updatingFromHex = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPrimary =
        ThemeData.estimateBrightnessForColor(_currentColor) == Brightness.dark
            ? Colors.white
            : Colors.black;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SilkySingleChildScrollView(
          silkyConfig: silkyScrollConfig,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Title & Live Preview Swatch
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Primary color'.i18n,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '#${_formatHex(_currentColor)}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _currentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 2D Saturation / Value Color Area
              _buildSaturationValuePicker(),
              const SizedBox(height: 14),

              // Rainbow Hue Slider
              _buildHueSlider(),
              const SizedBox(height: 14),

              // Hex Input & RGB / Copy-Paste Row
              _buildHexAndInfo(theme),
              const SizedBox(height: 16),

              // Presets Label
              Text(
                'Presets'.i18n,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),

              // Preset Colors Multi-Row Grid
              _buildPresetsGrid(),
              const SizedBox(height: 20),

              // Actions (Cancel / Apply)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Cancel'.i18n),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _currentColor,
                      foregroundColor: onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () {
                      widget.onColorSelected(_currentColor);
                      Navigator.of(context).pop();
                    },
                    child: Text('Apply'.i18n),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaturationValuePicker() {
    final baseHueColor =
        HSVColor.fromAHSV(1.0, _hsv.hue, 1.0, 1.0).toColor();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const height = 150.0;

        void updateFromOffset(Offset localPosition) {
          final sat = (localPosition.dx / width).clamp(0.0, 1.0);
          final val = (1.0 - (localPosition.dy / height)).clamp(0.0, 1.0);
          _updateColorFromHsv(_hsv.withSaturation(sat).withValue(val));
        }

        final thumbX = (_hsv.saturation * width).clamp(0.0, width);
        final thumbY = ((1.0 - _hsv.value) * height).clamp(0.0, height);

        return GestureDetector(
          onPanDown: (details) => updateFromOffset(details.localPosition),
          onPanUpdate: (details) => updateFromOffset(details.localPosition),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Horizontal gradient: White -> pure Hue
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.white, baseHueColor],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                    ),
                  ),
                ),
                // Vertical gradient: Transparent -> Black
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Colors.black],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
                // Crisp border
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                  ),
                ),
                // Draggable circular thumb indicator
                Positioned(
                  left: thumbX - 12,
                  top: thumbY - 12,
                  child: IgnorePointer(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _currentColor,
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black54,
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHueSlider() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 32,
          activeTrackColor: Colors.transparent,
          inactiveTrackColor: Colors.transparent,
          thumbColor: Colors.white,
          thumbShape: const RoundSliderThumbShape(
            enabledThumbRadius: 13,
            elevation: 4,
          ),
          overlayShape: SliderComponentShape.noOverlay,
        ),
        child: Slider(
          value: _hsv.hue,
          min: 0.0,
          max: 360.0,
          onChanged: (val) {
            _updateColorFromHsv(_hsv.withHue(val));
          },
        ),
      ),
    );
  }

  Widget _buildHexAndInfo(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _hexController,
            maxLength: 6,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
            ],
            decoration: InputDecoration(
              prefixText: '# ',
              labelText: 'Hex code'.i18n,
              counterText: '',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: _onHexSubmitted,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          icon: const Icon(Icons.paste, size: 18),
          tooltip: 'Paste hex code',
          onPressed: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            if (data?.text != null) {
              _onHexSubmitted(data!.text!);
            }
          },
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy hex code',
          onPressed: () {
            Clipboard.setData(
              ClipboardData(text: '#${_formatHex(_currentColor)}'),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPresetsGrid() {
    return Column(
      children: [
        for (int row = 0; row < 3; row++) ...[
          if (row > 0) const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (int col = 0; col < 9; col++)
                _buildPresetSwatch(
                  PrimaryColorPickerDialog.presetColors[row * 9 + col],
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildPresetSwatch(Color color) {
    final isSelected = color.toARGB32() == _currentColor.toARGB32();
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;

    return Tooltip(
      message: '#${_formatHex(color)}',
      child: InkWell(
        onTap: () => _onColorChanged(color),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? onColor.withValues(alpha: 0.95)
                  : Colors.black26,
              width: isSelected ? 2.5 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: isSelected
              ? Icon(Icons.check, color: onColor, size: 18)
              : null,
        ),
      ),
    );
  }
}
