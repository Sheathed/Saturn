import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:country_currency_pickers/country.dart';
import 'package:country_currency_pickers/country_picker_dialog.dart';
import 'package:country_currency_pickers/utils/utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_disk_space/universal_disk_space.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_displaymode/flutter_displaymode.dart';
//import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_material_color_picker/flutter_material_color_picker.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:fluttericon/web_symbols_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:i18n_extension/i18n_extension.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
//import 'package:permission_handler/permission_handler.dart';
import 'package:saturn/ui/log_screen.dart';
import 'package:saturn/ui/player_bar.dart';
import 'package:scrobblenaut/scrobblenaut.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:saturn/ui/toast.dart';
import 'package:external_path/external_path.dart';

import '../api/cache.dart';
import '../api/deezer.dart';
import '../main.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/downloads_screen.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../ui/home_screen.dart';
import '../ui/updater.dart';
import '../utils/file_utils.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Settings'.i18n),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text('General'.i18n),
            leading: const LeadingIcon(
              Icons.settings,
              color: Color(0xffeca704),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const GeneralSettings()),
            ),
          ),
          ListTile(
            title: Text('Download Settings'.i18n),
            leading: const LeadingIcon(
              Icons.cloud_download,
              color: Color(0xffbe3266),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const DownloadsSettings(),
              ),
            ),
          ),
          ListTile(
            title: Text('Appearance'.i18n),
            leading: const LeadingIcon(
              Icons.color_lens,
              color: Color(0xff4b2e7e),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AppearanceSettings(),
              ),
            ),
          ),
          ListTile(
            title: Text('Quality'.i18n),
            leading: const LeadingIcon(
              Icons.high_quality,
              color: Color(0xff384697),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const QualitySettings()),
            ),
          ),
          ListTile(
            title: Text('Deezer'.i18n),
            leading: const LeadingIcon(
              Icons.equalizer,
              color: Color(0xff0880b5),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const DeezerSettings()),
            ),
          ),
          //Language select
          ListTile(
            title: Text('Language'.i18n),
            leading: const LeadingIcon(
              Icons.language,
              color: Color(0xff009a85),
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text('Select language'.i18n),
                  children: List.generate(languages.length, (int i) {
                    Language l = languages[i];
                    return ListTile(
                      title: Text(l.name),
                      subtitle: Text('${l.locale}-${l.country}'),
                      onTap: () async {
                        I18n.of(context).locale = Locale(l.locale, l.country);
                        setState(
                          () => settings.language = '${l.locale}-${l.country}',
                        );
                        await settings.save();
                        // Close the SimpleDialog
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    );
                  }),
                ),
              );
            },
          ),
          ListTile(
            title: Text('Updates'.i18n),
            leading: const LeadingIcon(Icons.update, color: Color(0xff2ba766)),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const UpdaterScreen()),
            ),
          ),
          ListTile(
            title: Text('About'.i18n),
            leading: const LeadingIcon(Icons.info, color: Colors.grey),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const CreditsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class LicenseDetail extends StatelessWidget {
  final String title;
  final String content;

  const LicenseDetail({required this.title, required this.content, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(title),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: SelectableText(
          content.isNotEmpty ? content : 'No license text available'.i18n,
          style: const TextStyle(fontSize: 14.0),
        ),
      ),
    );
  }
}

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  _AppearanceSettingsState createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  ColorSwatch<dynamic> _swatch(int c) => ColorSwatch(c, {500: Color(c)});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Appearance'.i18n),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text('Theme'.i18n),
            subtitle: Text(
              'Currently'.i18n +
                  ': ${settings.theme.toString().split('.').last}',
            ),
            leading: const Icon(Icons.color_lens),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return SimpleDialog(
                    title: Text('Select theme'.i18n),
                    children: <Widget>[
                      SimpleDialogOption(
                        child: Text('Light'.i18n),
                        onPressed: () {
                          setState(() => settings.theme = Themes.Light);
                          settings.save();
                          updateTheme();
                          Navigator.of(context).pop();
                        },
                      ),
                      SimpleDialogOption(
                        child: Text('Dark'.i18n),
                        onPressed: () {
                          setState(() => settings.theme = Themes.Dark);
                          settings.save();
                          updateTheme();
                          Navigator.of(context).pop();
                        },
                      ),
                      SimpleDialogOption(
                        child: Text('Black (AMOLED)'.i18n),
                        onPressed: () {
                          setState(() => settings.theme = Themes.Black);
                          settings.save();
                          updateTheme();
                          Navigator.of(context).pop();
                        },
                      ),
                      SimpleDialogOption(
                        child: Text('Deezer (Dark)'.i18n),
                        onPressed: () {
                          setState(() => settings.theme = Themes.Deezer);
                          settings.save();
                          updateTheme();
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
          ListTile(
            title: Text('Use system theme'.i18n),
            trailing: Switch(
              value: settings.useSystemTheme,
              onChanged: (bool v) async {
                setState(() {
                  settings.useSystemTheme = v;
                });
                updateTheme();
                await settings.save();
              },
            ),
            leading: Platform.isAndroid
                ? Icon(Icons.android)
                : Platform.isIOS
                ? Icon(Icons.apple)
                : Icon(Icons.computer),
          ),
          ListTile(
            title: Text('Font'.i18n),
            leading: const Icon(Icons.font_download),
            subtitle: Text(settings.font),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) =>
                    FontSelector(() => Navigator.of(context).pop()),
              );
            },
          ),
          ListTile(
            title: Text('Player gradient background'.i18n),
            leading: const Icon(Icons.colorize),
            trailing: Switch(
              value: settings.colorGradientBackground,
              onChanged: (bool v) async {
                setState(() => settings.colorGradientBackground = v);
                await settings.save();
                GetIt.I<PlayerBarState>().updateBackground();
              },
            ),
          ),
          ListTile(
            title: Text('Blur player background'.i18n),
            subtitle: Text('Might have impact on performance'.i18n),
            leading: const Icon(Icons.blur_on),
            trailing: Switch(
              value: settings.blurPlayerBackground,
              onChanged: (bool v) async {
                setState(() => settings.blurPlayerBackground = v);
                await settings.save();
                GetIt.I<PlayerBarState>().updateBackground();
              },
            ),
          ),
          ListTile(
            title: Text('Theme Additonal Items'.i18n),
            subtitle: Text(
              'Themes additional items like mini player and lyrics'.i18n,
            ),
            leading: const Icon(Icons.library_add),
            trailing: Switch(
              value: settings.themeAdditonalItems,
              onChanged: (bool v) async {
                setState(() => settings.themeAdditonalItems = v);
                await settings.save();
                GetIt.I<PlayerBarState>().updateBackground();
              },
            ),
          ),
          ListTile(
            title: Text('Visualizer'.i18n),
            subtitle: Text(
              'Show visualizers on lyrics page. WARNING: Requires microphone permission!'
                  .i18n,
            ),
            leading: const Icon(Icons.equalizer),
            trailing: Switch(
              value: settings.lyricsVisualizer,
              onChanged: null,
              // onChanged: (bool v) async {
              //   if (await Permission.microphone.request().isGranted) {
              //     setState(() => settings.lyricsVisualizer = v);
              //     await settings.save();
              //     return;
              //   }
              // },
            ),
            enabled: false,
          ),
          ListTile(
            title: Text('Primary color'.i18n),
            leading: const Icon(Icons.format_paint),
            subtitle: Text(
              'Selected color'.i18n,
              style: TextStyle(color: settings.primaryColor),
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('Primary color'.i18n),
                    content: SizedBox(
                      height: 240,
                      child: MaterialColorPicker(
                        colors: [
                          ...Colors.primaries,
                          //Logo colors
                          _swatch(0xffeca704),
                          _swatch(0xffbe3266),
                          _swatch(0xff4b2e7e),
                          _swatch(0xff384697),
                          _swatch(0xff0880b5),
                          _swatch(0xff009a85),
                          _swatch(0xff2ba766),
                        ],
                        allowShades: false,
                        selectedColor: settings.primaryColor,
                        onMainColorChange: (ColorSwatch? color) {
                          setState(() {
                            settings.primaryColor = color!;
                          });
                          settings.save();
                          updateTheme();
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),
          ListTile(
            title: Text('Use album art primary color'.i18n),
            subtitle: Text('Warning: might be buggy'.i18n),
            leading: const Icon(Icons.invert_colors),
            trailing: Switch(
              value: settings.useArtColor,
              onChanged: (v) => setState(() => settings.updateUseArtColor(v)),
            ),
          ),
          ListTile(
            title: Text('Keep Sidebar Open'.i18n),
            leading: const Icon(Icons.view_sidebar),
            trailing: Switch(
              value: settings.keepSidebarOpen,
              onChanged: (v) =>
                  setState(() => settings.updateKeepSidebar(v, true)),
            ),
          ),
          ListTile(
            title: Text('Keep Sidebar Closed'.i18n),
            leading: const Icon(Icons.view_sidebar),
            trailing: Switch(
              value: settings.keepSidebarClosed,
              onChanged: (v) =>
                  setState(() => settings.updateKeepSidebar(v, false)),
            ),
          ),
          //Display mode
          ListTile(
            leading: const Icon(Icons.screen_lock_portrait),
            title: Text('Change display mode'.i18n),
            subtitle: Text('Enable high refresh rates'.i18n),
            onTap: () async {
              List modes = await FlutterDisplayMode.supported;
              if (!context.mounted) return;
              showDialog(
                context: context,
                builder: (context) {
                  return SimpleDialog(
                    title: Text('Display mode'.i18n),
                    children: List.generate(
                      modes.length,
                      (i) => SimpleDialogOption(
                        child: Text(modes[i].toString()),
                        onPressed: () async {
                          settings.displayMode = i;
                          await settings.save();
                          await FlutterDisplayMode.setPreferredMode(modes[i]);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class FontSelector extends StatefulWidget {
  final Function callback;

  const FontSelector(this.callback, {super.key});

  @override
  _FontSelectorState createState() => _FontSelectorState();
}

class _FontSelectorState extends State<FontSelector> {
  String query = '';
  List<String> get fonts {
    return settings.fonts
        .where((f) => f.toLowerCase().contains(query))
        .toList();
  }

  //Font selected
  void onTap(String font) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Warning'.i18n),
        content: Text(
          "This app isn't made for supporting many fonts, it can break layouts and overflow. Use at your own risk!"
              .i18n,
        ),
        actions: [
          TextButton(
            style: ButtonStyle(
              overlayColor: material.WidgetStateProperty.resolveWith<Color?>((
                Set<material.WidgetState> states,
              ) {
                if (states.contains(material.WidgetState.pressed)) {
                  return Theme.of(context).primaryColor.withValues(alpha: 0.3);
                }
                return null;
              }),
            ),
            onPressed: () async {
              setState(() => settings.font = font);
              await settings.save();
              if (context.mounted) Navigator.of(context).pop();
              widget.callback();
              //Global setState
              updateTheme();
            },
            child: Text('Apply'.i18n),
          ),
          TextButton(
            style: const ButtonStyle(),
            onPressed: () {
              Navigator.of(context).pop();
              widget.callback();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text('Select font'.i18n),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
          child: TextField(
            cursorColor: Theme.of(context).primaryColor,
            decoration: InputDecoration(hintText: 'Search'.i18n),
            onChanged: (q) => setState(() => query = q),
          ),
        ),
        ...List.generate(
          fonts.length,
          (i) => SimpleDialogOption(
            child: Text(fonts[i]),
            onPressed: () => onTap(fonts[i]),
          ),
        ),
      ],
    );
  }
}

class QualitySettings extends StatefulWidget {
  const QualitySettings({super.key});

  @override
  _QualitySettingsState createState() => _QualitySettingsState();
}

class _QualitySettingsState extends State<QualitySettings> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Quality'.i18n),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text('Mobile streaming'.i18n),
            leading: const LeadingIcon(
              Icons.network_cell,
              color: Color(0xff384697),
            ),
          ),
          const QualityPicker('mobile'),
          const FreezerDivider(),
          ListTile(
            title: Text('Wifi streaming'.i18n),
            leading: const LeadingIcon(
              Icons.network_wifi,
              color: Color(0xff0880b5),
            ),
          ),
          const QualityPicker('wifi'),
          const FreezerDivider(),
          ListTile(
            title: Text('Offline'.i18n),
            leading: const LeadingIcon(
              Icons.offline_pin,
              color: Color(0xff009a85),
            ),
          ),
          const QualityPicker('offline'),
          const FreezerDivider(),
          ListTile(
            title: Text('External downloads'.i18n),
            leading: const LeadingIcon(
              Icons.file_download,
              color: Color(0xff2ba766),
            ),
          ),
          const QualityPicker('download'),
        ],
      ),
    );
  }
}

class QualityPicker extends StatefulWidget {
  final String field;
  const QualityPicker(this.field, {super.key});

  @override
  _QualityPickerState createState() => _QualityPickerState();
}

class _QualityPickerState extends State<QualityPicker> {
  late AudioQuality _quality;

  @override
  void initState() {
    _getQuality();
    super.initState();
  }

  //Get current quality
  void _getQuality() {
    switch (widget.field) {
      case 'mobile':
        _quality = settings.mobileQuality;
        break;
      case 'wifi':
        _quality = settings.wifiQuality;
        break;
      case 'download':
        _quality = settings.downloadQuality;
        break;
      case 'offline':
        _quality = settings.offlineQuality;
        break;
    }
  }

  //Update quality in settings
  void _updateQuality(AudioQuality q) async {
    setState(() {
      _quality = q;
    });
    switch (widget.field) {
      case 'mobile':
        settings.mobileQuality = _quality;
        await GetIt.I<AudioPlayerHandler>().updateQueueQuality();
        break;
      case 'wifi':
        settings.wifiQuality = _quality;
        await GetIt.I<AudioPlayerHandler>().updateQueueQuality();
        break;
      case 'download':
        settings.downloadQuality = _quality;
        break;
      case 'offline':
        settings.offlineQuality = _quality;
        break;
    }
    await settings.save();
  }

  @override
  Widget build(BuildContext context) {
    return RadioGroup<AudioQuality>(
      groupValue: _quality,
      onChanged: (q) => _updateQuality(q!),
      child: Column(
        children: [
          const RadioListTile<AudioQuality>(
            title: Text('MP3 128kbps'),
            value: AudioQuality.MP3_128,
          ),
          const RadioListTile<AudioQuality>(
            title: Text('MP3 320kbps'),
            value: AudioQuality.MP3_320,
          ),
          const RadioListTile<AudioQuality>(
            title: Text('FLAC'),
            value: AudioQuality.FLAC,
          ),
          if (widget.field == 'download')
            RadioListTile<AudioQuality>(
              title: Text('Ask before downloading'.i18n),
              value: AudioQuality.ASK,
            ),
        ],
      ),
    );
  }
}

class ContentLanguage {
  String code;
  String name;
  ContentLanguage(this.code, this.name);

  static List<ContentLanguage> get all => [
    ContentLanguage('cs', 'Čeština'),
    ContentLanguage('da', 'Dansk'),
    ContentLanguage('de', 'Deutsch'),
    ContentLanguage('en', 'English'),
    ContentLanguage('us', 'English (us)'),
    ContentLanguage('es', 'Español'),
    ContentLanguage('mx', 'Español (latam)'),
    ContentLanguage('fr', 'Français'),
    ContentLanguage('hr', 'Hrvatski'),
    ContentLanguage('id', 'Indonesia'),
    ContentLanguage('it', 'Italiano'),
    ContentLanguage('hu', 'Magyar'),
    ContentLanguage('ms', 'Melayu'),
    ContentLanguage('nl', 'Nederlands'),
    ContentLanguage('no', 'Norsk'),
    ContentLanguage('pl', 'Polski'),
    ContentLanguage('br', 'Português (br)'),
    ContentLanguage('pt', 'Português (pt)'),
    ContentLanguage('ro', 'Română'),
    ContentLanguage('sk', 'Slovenčina'),
    ContentLanguage('sl', 'Slovenščina'),
    ContentLanguage('sq', 'Shqip'),
    ContentLanguage('sr', 'Srpski'),
    ContentLanguage('fi', 'Suomi'),
    ContentLanguage('sv', 'Svenska'),
    ContentLanguage('tr', 'Türkçe'),
    ContentLanguage('bg', 'Български'),
    ContentLanguage('ru', 'Pусский'),
    ContentLanguage('uk', 'Українська'),
    ContentLanguage('he', 'עִברִית'),
    ContentLanguage('ar', 'العربیة'),
    ContentLanguage('cn', '中文'),
    ContentLanguage('ja', '日本語'),
    ContentLanguage('ko', '한국어'),
    ContentLanguage('th', 'ภาษาไทย'),
  ];
}

class DeezerSettings extends StatefulWidget {
  const DeezerSettings({super.key});

  @override
  _DeezerSettingsState createState() => _DeezerSettingsState();
}

class _DeezerSettingsState extends State<DeezerSettings> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Deezer'.i18n),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text('Content language'.i18n),
            subtitle: Text(
              'Not app language, used in headers. Now'.i18n +
                  ': ${settings.deezerLanguage}',
            ),
            leading: const Icon(Icons.language),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text('Select language'.i18n),
                  children: List.generate(
                    ContentLanguage.all.length,
                    (i) => ListTile(
                      title: Text(ContentLanguage.all[i].name),
                      subtitle: Text(ContentLanguage.all[i].code),
                      onTap: () async {
                        setState(
                          () => settings.deezerLanguage =
                              ContentLanguage.all[i].code,
                        );
                        await settings.save();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          ListTile(
            title: Text('Content country'.i18n),
            subtitle: Text(
              'Country used in headers. Now'.i18n +
                  ': ${settings.deezerCountry}',
            ),
            leading: const Icon(Icons.vpn_lock),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => CountryPickerDialog(
                  title: Text('Select country'.i18n),
                  titlePadding: const EdgeInsets.all(8.0),
                  isSearchable: true,
                  itemBuilder: (country) => Row(
                    children: <Widget>[
                      CountryPickerUtils.getDefaultFlagImage(country),
                      const SizedBox(width: 8.0),
                      Expanded(
                        child: Text('${country.name} (${country.isoCode})'),
                      ),
                    ],
                  ),
                  onValuePicked: (Country country) {
                    setState(
                      () => settings.deezerCountry = country.isoCode ?? 'us',
                    );
                    settings.save();
                  },
                ),
              );
            },
          ),
          ListTile(
            title: Text('Log tracks'.i18n),
            subtitle: Text(
              'Send track listen logs to Deezer, enable it for features like Flow to work properly'
                  .i18n,
            ),
            trailing: Switch(
              value: settings.logListen,
              onChanged: (bool v) {
                setState(() => settings.logListen = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.history_toggle_off),
          ),
          //todo: Reimplement proxy
          //          ListTile(
          //            title: Text('Proxy'.i18n),
          //            leading: Icon(Icons.vpn_key),
          //            subtitle: Text(settings.proxyAddress??'Not set'.i18n),
          //            onTap: () {
          //              String _new;
          //              showDialog(
          //                context: context,
          //                builder: (BuildContext context) {
          //                  return AlertDialog(
          //                    title: Text('Proxy'.i18n),
          //                    content: TextField(
          //                      onChanged: (String v) => _new = v,
          //                      decoration: InputDecoration(
          //                        hintText: 'IP:PORT'
          //                      ),
          //                    ),
          //                    actions: [
          //                      TextButton(
          //                        child: Text('Cancel'.i18n),
          //                        onPressed: () => Navigator.of(context).pop(),
          //                      ),
          //                      TextButton(
          //                        child: Text('Reset'.i18n),
          //                        onPressed: () async {
          //                          setState(() {
          //                            settings.proxyAddress = null;
          //                          });
          //                          await settings.save();
          //                          Navigator.of(context).pop();
          //                        },
          //                      ),
          //                      TextButton(
          //                        child: Text('Save'.i18n),
          //                        onPressed: () async {
          //                          setState(() {
          //                            settings.proxyAddress = _new;
          //                          });
          //                          await settings.save();
          //                          Navigator.of(context).pop();
          //                        },
          //                      )
          //                    ],
          //                  );
          //                }
          //              );
          //            },
          //          )
        ],
      ),
    );
  }
}

class FilenameTemplateDialog extends StatefulWidget {
  final String initial;
  final Function onSave;
  const FilenameTemplateDialog(this.initial, this.onSave, {super.key});

  @override
  _FilenameTemplateDialogState createState() => _FilenameTemplateDialogState();
}

class _FilenameTemplateDialogState extends State<FilenameTemplateDialog> {
  late TextEditingController _controller;
  late String _new;

  @override
  void initState() {
    _controller = TextEditingController(text: widget.initial);
    _new = _controller.value.text;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    //Dialog with filename format
    return AlertDialog(
      title: Text('Downloaded tracks filename'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            decoration: InputDecoration(
              floatingLabelStyle: TextStyle(
                color: Theme.of(context).primaryColor,
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).primaryColor,
                ), // Color of the underline when focused
              ),
            ),
            cursorColor: Theme.of(context).primaryColor,
            controller: _controller,
            onChanged: (String s) => _new = s,
          ),
          Container(height: 8.0),
          Text(
            'Valid variables are'.i18n +
                ': %artists%, %artist%, %title%, %album%, %trackNumber%, %0trackNumber%, %feats%, %playlistTrackNumber%, %0playlistTrackNumber%, %year%, %date%\n\n' +
                "If you want to use custom directory naming - use '/' as directory separator."
                    .i18n,
            style: const TextStyle(fontSize: 12.0),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Cancel'.i18n),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Reset'.i18n),
          onPressed: () {
            _controller.value = _controller.value.copyWith(
              text: '%artist% - %title%',
            );
            _new = '%artist% - %title%';
          },
        ),
        TextButton(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Clear'.i18n),
          onPressed: () => _controller.clear(),
        ),
        TextButton(
          style: ButtonStyle(
            overlayColor: material.WidgetStateProperty.resolveWith<Color?>((
              Set<material.WidgetState> states,
            ) {
              if (states.contains(material.WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Save'.i18n),
          onPressed: () {
            widget.onSave(_new);
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class DownloadsSettings extends StatefulWidget {
  const DownloadsSettings({super.key});

  @override
  _DownloadsSettingsState createState() => _DownloadsSettingsState();
}

class _DownloadsSettingsState extends State<DownloadsSettings> {
  double _downloadThreads = settings.downloadThreads.toDouble();
  final TextEditingController _artistSeparatorController =
      TextEditingController(text: settings.artistSeparator);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Download Settings'.i18n),
      body: ListView(
        children: [
          ListTile(
            title: Text('Download path'.i18n),
            leading: const Icon(Icons.folder),
            subtitle: Text(settings.downloadPath ?? 'Not set'.i18n),
            onTap: () async {
              //Check permissions
              //if (!(await Permission.storage.request().isGranted)) return;
              if (await FileUtils.checkStoragePermission()) {
                //Navigate
                if (context.mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => DirectoryPicker(
                        settings.downloadPath ?? '',
                        onSelect: (String p) async {
                          setState(() => settings.downloadPath = p);
                          await settings.save();
                        },
                      ),
                    ),
                  );
                }
              } else {
                Fluttertoast.showToast(
                  msg: 'Storage permission denied!'.i18n,
                  toastLength: Toast.LENGTH_SHORT,
                  gravity: ToastGravity.BOTTOM,
                );
                return;
              }
            },
          ),
          ListTile(
            title: Text('Downloads naming'.i18n),
            subtitle: Text('Currently'.i18n + ': ${settings.downloadFilename}'),
            leading: const Icon(Icons.text_format),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return FilenameTemplateDialog(settings.downloadFilename, (
                    f,
                  ) async {
                    setState(() => settings.downloadFilename = f);
                    await settings.save();
                  });
                },
              );
            },
          ),
          ListTile(
            title: Text('Singleton naming'.i18n),
            subtitle: Text(
              'Currently'.i18n + ': ${settings.singletonFilename}',
            ),
            leading: const Icon(Icons.text_format),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return FilenameTemplateDialog(settings.singletonFilename, (
                    f,
                  ) async {
                    setState(() => settings.singletonFilename = f);
                    await settings.save();
                  });
                },
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              'Download threads'.i18n +
                  ': ${_downloadThreads.round().toString()}',
              style: const TextStyle(fontSize: 16.0),
            ),
          ),
          Slider(
            min: 1,
            max: 16,
            divisions: 15,
            value: _downloadThreads,
            label: _downloadThreads.round().toString(),
            onChanged: (double v) => setState(() => _downloadThreads = v),
            onChangeEnd: (double val) async {
              _downloadThreads = val;
              setState(() {
                settings.downloadThreads = _downloadThreads.round();
                _downloadThreads = settings.downloadThreads.toDouble();
              });
              await settings.save();

              //Prevent null
              if (val > 8 && cache.threadsWarning != true && context.mounted) {
                showDialog(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      title: Text('Warning'.i18n),
                      content: Text(
                        'Using too many concurrent downloads on older/weaker devices might cause crashes!'
                            .i18n,
                      ),
                      actions: [
                        TextButton(
                          style: ButtonStyle(
                            overlayColor:
                                WidgetStateProperty.resolveWith<Color?>((
                                  Set<WidgetState> states,
                                ) {
                                  if (states.contains(WidgetState.pressed)) {
                                    return Theme.of(
                                      context,
                                    ).primaryColor.withValues(alpha: 0.3);
                                  }
                                  return null;
                                }),
                          ),
                          child: Text('Dismiss'.i18n),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    );
                  },
                );

                cache.threadsWarning = true;
                await cache.save();
              }
            },
          ),
          const FreezerDivider(),
          ListTile(
            title: Text('Tags'.i18n),
            leading: const Icon(Icons.label),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const TagSelectionScreen(),
              ),
            ),
          ),
          ListTile(
            title: Text('Create folders for artist'.i18n),
            trailing: Switch(
              value: settings.artistFolder,
              onChanged: (v) {
                setState(() => settings.artistFolder = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.folder),
          ),
          ListTile(
            title: Text('Create folders for albums'.i18n),
            trailing: Switch(
              value: settings.albumFolder,
              onChanged: (v) {
                setState(() => settings.albumFolder = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.folder),
          ),
          ListTile(
            title: Text('Create folder for playlist'.i18n),
            trailing: Switch(
              value: settings.playlistFolder,
              onChanged: (v) {
                setState(() => settings.playlistFolder = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.folder),
          ),
          const FreezerDivider(),
          ListTile(
            title: Text('Separate albums by discs'.i18n),
            trailing: Switch(
              value: settings.albumDiscFolder,
              onChanged: (v) {
                setState(() => settings.albumDiscFolder = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.album),
          ),
          ListTile(
            title: Text('Overwrite already downloaded files'.i18n),
            trailing: Switch(
              value: settings.overwriteDownload,
              onChanged: (v) {
                setState(() => settings.overwriteDownload = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.delete),
          ),
          ListTile(
            title: Text('Download .LRC lyrics'.i18n),
            trailing: Switch(
              value: settings.downloadLyrics,
              onChanged: (v) {
                setState(() => settings.downloadLyrics = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.subtitles),
          ),
          const FreezerDivider(),
          ListTile(
            title: Text('Save cover file for every track'.i18n),
            trailing: Switch(
              value: settings.trackCover,
              onChanged: (v) {
                setState(() => settings.trackCover = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.image),
          ),
          ListTile(
            title: Text('Save album cover'.i18n),
            trailing: Switch(
              value: settings.albumCover,
              onChanged: (v) {
                setState(() => settings.albumCover = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.image),
          ),
          ListTile(
            title: Text('Album cover resolution'.i18n),
            subtitle: Text(
              "WARNING: Resolutions above 1200 aren't officially supported"
                  .i18n,
            ),
            leading: const Icon(Icons.image),
            trailing: SizedBox(
              width: 75.0,
              child: DropdownButton<int>(
                value: settings.albumArtResolution,
                items: [400, 800, 1000, 1200, 1400, 1600, 1800]
                    .map<DropdownMenuItem<int>>(
                      (int i) => DropdownMenuItem<int>(
                        value: i,
                        child: Text(i.toString()),
                      ),
                    )
                    .toList(),
                onChanged: (int? n) async {
                  setState(() {
                    settings.albumArtResolution = n ?? 400;
                  });
                  await settings.save();
                },
              ),
            ),
          ),
          ListTile(
            title: Text('Create .nomedia files'.i18n),
            subtitle: Text(
              'To prevent gallery being filled with album art'.i18n,
            ),
            trailing: Switch(
              value: settings.nomediaFiles,
              onChanged: (v) {
                setState(() => settings.nomediaFiles = v);
                settings.save();
              },
            ),
            leading: const Icon(Icons.insert_drive_file),
          ),
          ListTile(
            title: Text('Artist separator'.i18n),
            leading: const Icon(WebSymbols.tag),
            trailing: SizedBox(
              width: 75.0,
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                controller: _artistSeparatorController,
                onChanged: (s) async {
                  settings.artistSeparator = s;
                  await settings.save();
                },
                decoration: InputDecoration(
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(context).primaryColor,
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).primaryColor,
                    ), // Color of the underline when focused
                  ),
                ),
              ),
            ),
          ),
          const FreezerDivider(),
          ListTile(
            title: Text('Download Log'.i18n),
            leading: const Icon(Icons.sticky_note_2),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const DownloadLogViewer(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TagOption {
  String title;
  String value;
  TagOption(this.title, this.value);
}

class TagSelectionScreen extends StatefulWidget {
  const TagSelectionScreen({super.key});

  @override
  _TagSelectionScreenState createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  List<TagOption> tags = [
    TagOption('Title'.i18n, 'title'),
    TagOption('Album'.i18n, 'album'),
    TagOption('Artist'.i18n, 'artist'),
    TagOption('Track number'.i18n, 'track'),
    TagOption('Disc number'.i18n, 'disc'),
    TagOption('Album artist'.i18n, 'albumArtist'),
    TagOption('Date/Year'.i18n, 'date'),
    TagOption('Label'.i18n, 'label'),
    TagOption('ISRC'.i18n, 'isrc'),
    TagOption('UPC'.i18n, 'upc'),
    TagOption('Track total'.i18n, 'trackTotal'),
    TagOption('BPM'.i18n, 'bpm'),
    TagOption('Unsynchronized lyrics'.i18n, 'lyrics'),
    TagOption('Genre'.i18n, 'genre'),
    TagOption('Contributors'.i18n, 'contributors'),
    TagOption('Album art'.i18n, 'art'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Tags'.i18n),
      body: ListView(
        children: List.generate(
          tags.length,
          (i) => ListTile(
            title: Text(tags[i].title),
            leading: Switch(
              value: settings.tags.contains(tags[i].value),
              onChanged: (v) async {
                //Update
                if (v) {
                  settings.tags.add(tags[i].value);
                } else {
                  settings.tags.remove(tags[i].value);
                }
                setState(() {});
                await settings.save();
              },
            ),
          ),
        ),
      ),
    );
  }
}

class GeneralSettings extends StatefulWidget {
  const GeneralSettings({super.key});

  @override
  _GeneralSettingsState createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends State<GeneralSettings> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('General'.i18n),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text('Offline mode'.i18n),
            subtitle: Text('Will be overwritten on start.'.i18n),
            trailing: Switch(
              value: settings.offlineMode,
              onChanged: (bool v) {
                if (v) {
                  setState(() => settings.offlineMode = true);
                  return;
                }
                showDialog(
                  context: context,
                  builder: (context) {
                    deezerAPI.authorize().then((v) async {
                      if (v) {
                        setState(() => settings.offlineMode = false);
                      } else {
                        Fluttertoast.showToast(
                          msg:
                              'Error logging in, check your internet connections.'
                                  .i18n,
                          gravity: ToastGravity.BOTTOM,
                          toastLength: Toast.LENGTH_SHORT,
                        );
                      }
                      if (context.mounted) Navigator.of(context).pop();
                      if (context.mounted) Navigator.of(context).pop();
                    });
                    return AlertDialog(
                      title: Text('Logging in...'.i18n),
                      content: const Row(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[CircularProgressIndicator()],
                      ),
                    );
                  },
                );
              },
            ),
            leading: const Icon(Icons.lock),
          ),
          ListTile(
            title: Text('Copy ARL'.i18n),
            subtitle: Text(
              'Copy userToken/ARL Cookie for use in other apps.'.i18n,
            ),
            leading: const Icon(Icons.lock),
            onTap: () async {
              await FlutterClipboard.copy(settings.arl ?? '');
              await Fluttertoast.showToast(msg: 'Copied'.i18n);
            },
          ),
          ListTile(
            title: Text('Enable equalizer'.i18n),
            subtitle: Text(
              'Might enable some equalizer apps to work. Requires restart of Saturn'
                  .i18n,
            ),
            leading: const Icon(Icons.equalizer),
            trailing: Switch(
              value: settings.enableEqualizer,
              onChanged: (v) async {
                setState(() => settings.enableEqualizer = v);
                settings.save();
              },
            ),
          ),
          if (!Platform.isAndroid && !Platform.isIOS)
            ListTile(
              title: Text('Enable Discord RPC'.i18n),
              leading: const Icon(Icons.discord),
              trailing: Switch(
                value: settings.enableDiscordRPC,
                onChanged: (v) async {
                  setState(() => settings.enableDiscordRPC = v);
                  settings.save();
                },
              ),
            ),
          ListTile(
            title: Text('LastFM'.i18n),
            subtitle: Text(
              (settings.lastFMUsername != null)
                  ? 'Log out'.i18n
                  : 'Login to enable scrobbling.'.i18n,
            ),
            leading: const Icon(FontAwesome5.lastfm),
            onTap: () async {
              if (settings.lastFMUsername != null) {
                //Log out
                settings.lastFMUsername = null;
                settings.lastFMPassword = null;
                await settings.save();
                await GetIt.I<AudioPlayerHandler>().disableLastFM();
                //await GetIt.I<AudioPlayerHandler>().customAction('disableLastFM', Map<String, dynamic>());
                setState(() {});
                Fluttertoast.showToast(msg: 'Logged out!'.i18n);
                return;
              } else {
                showDialog(
                  context: context,
                  builder: (context) => const LastFMLogin(),
                ).then((_) {
                  setState(() {});
                });
              }
            },
            //enabled: false,
          ),
          ListTile(
            title: Text('LastFM API Key'.i18n),
            leading: const Icon(Icons.key),
            trailing: SizedBox(
              width: 75.0,
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                onChanged: (s) async {
                  settings.lastFMAPIKey = s;
                  await settings.save();
                },
                decoration: InputDecoration(
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(context).primaryColor,
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).primaryColor,
                    ), // Color of the underline when focused
                  ),
                ),
              ),
            ),
          ),
          ListTile(
            title: Text('LastFM API Secret'.i18n),
            leading: const Icon(Icons.warning),
            trailing: SizedBox(
              width: 75.0,
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                onChanged: (s) async {
                  settings.lastFMAPISecret = s;
                  await settings.save();
                },
                decoration: InputDecoration(
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(context).primaryColor,
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).primaryColor,
                    ), // Color of the underline when focused
                  ),
                ),
              ),
            ),
          ),
          ListTile(
            title: Text('Ignore interruptions'.i18n),
            subtitle: Text('Requires app restart to apply!'.i18n),
            leading: const Icon(Icons.not_interested),
            trailing: Switch(
              value: settings.ignoreInterruptions,
              onChanged: (bool v) async {
                setState(() => settings.ignoreInterruptions = v);
                await settings.save();
              },
            ),
          ),
          ListTile(
            title: Text('Disable Eastereggs'.i18n),
            leading: const Icon(Icons.egg),
            trailing: Switch(
              value: settings.eastereggsDisabled,
              onChanged: (bool v) async {
                setState(() => settings.eastereggsDisabled = v);
                settings.stopRainbowColorUpdates();
                await settings.save();
              },
            ),
          ),
          ListTile(
            title: Text('Application Log'.i18n),
            leading: const Icon(Icons.sticky_note_2),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const ApplicationLogViewer(),
              ),
            ),
          ),
          const FreezerDivider(),
          ListTile(
            title: Text(
              'Log out'.i18n,
              style: const TextStyle(color: Colors.red),
            ),
            leading: const Icon(Icons.exit_to_app),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('Log out'.i18n),
                    // There was no Incompatability, cookies just needed to be cleared...
                    // content: Text('Due to plugin incompatibility, login using browser is unavailable without restart.'.i18n),
                    // content: Text('Restart of app is required to properly log out!'.i18n),
                    content: Text('Are you sure you want to log out?'.i18n),
                    actions: <Widget>[
                      TextButton(
                        style: ButtonStyle(
                          overlayColor: WidgetStateProperty.resolveWith<Color?>(
                            (Set<WidgetState> states) {
                              if (states.contains(WidgetState.pressed)) {
                                return Theme.of(
                                  context,
                                ).primaryColor.withValues(alpha: 0.3);
                              }
                              return null;
                            },
                          ),
                        ),
                        child: Text('Cancel'.i18n),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      TextButton(
                        style: ButtonStyle(
                          overlayColor: WidgetStateProperty.resolveWith<Color?>(
                            (Set<WidgetState> states) {
                              if (states.contains(WidgetState.pressed)) {
                                return Theme.of(
                                  context,
                                ).primaryColor.withValues(alpha: 0.3);
                              }
                              return null;
                            },
                          ),
                        ),
                        //child: Text('(ARL ONLY) Continue'.i18n),
                        child: Text('Continue'.i18n),
                        onPressed: () async {
                          await logOut();
                          if (context.mounted) Navigator.of(context).pop();
                          updateTheme();
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class LastFMLogin extends StatefulWidget {
  const LastFMLogin({super.key});

  @override
  _LastFMLoginState createState() => _LastFMLoginState();
}

class _LastFMLoginState extends State<LastFMLogin> {
  String _username = '';
  String _password = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Login to LastFM'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            cursorColor: Theme.of(context).primaryColor,
            decoration: InputDecoration(
              hintText: 'Username'.i18n,
              floatingLabelStyle: TextStyle(
                color: Theme.of(context).primaryColor,
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Theme.of(context).primaryColor),
              ),
            ),
            onChanged: (v) => _username = v,
          ),
          Container(height: 8.0),
          TextField(
            cursorColor: Theme.of(context).primaryColor,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Password'.i18n,
              floatingLabelStyle: TextStyle(
                color: Theme.of(context).primaryColor,
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Theme.of(context).primaryColor),
              ),
            ),
            onChanged: (v) => _password = v,
          ),
        ],
      ),
      actions: [
        TextButton(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Cancel'.i18n),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return Theme.of(context).primaryColor.withValues(alpha: 0.3);
              }
              return null;
            }),
          ),
          child: Text('Login'.i18n),
          onPressed: () async {
            LastFM last;
            try {
              last = await LastFM.authenticate(
                apiKey: settings.lastFMAPIKey ?? '',
                apiSecret: settings.lastFMAPISecret ?? '',
                username: _username,
                password: _password,
              );
            } catch (e) {
              Logger.root.severe('Error authorizing LastFM: $e');
              Fluttertoast.showToast(msg: 'Authorization error!'.i18n);
              return;
            }
            //Save
            settings.lastFMUsername = last.username;
            settings.lastFMPassword = last.passwordHash;
            await settings.save();
            await GetIt.I<AudioPlayerHandler>().authorizeLastFM();
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class StorageInfo {
  final String rootDir;
  final String appFilesDir;
  final int availableBytes;

  StorageInfo({
    required this.rootDir,
    required this.appFilesDir,
    required this.availableBytes,
  });
}

Future<List<StorageInfo>> getStorageInfo() async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    // Initializes the DiskSpace class.
    final diskSpace = DiskSpace();

    // Scan for disks in the system.
    await diskSpace.scan();
    final externalDirectories = diskSpace.disks;

    List<StorageInfo> storageInfoList = [];

    if (externalDirectories.isNotEmpty) {
      for (final disk in externalDirectories) {
        var availableMegaBytes = disk.availableSpace / 1048576;

        storageInfoList.add(
          StorageInfo(
            rootDir: disk.devicePath,
            appFilesDir: disk.mountPath,
            availableBytes: availableMegaBytes > 0
                ? (availableMegaBytes * 1000000).floor()
                : 0,
          ),
        );
      }
    }

    return storageInfoList;
  } else {
    List<Directory?>? externalDirectories;
    if (Platform.isAndroid) {
      externalDirectories = await getExternalStorageDirectories();
      externalDirectories?.add(
        Directory(
          await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_MUSIC,
          ),
        ),
      );
    } else {
      externalDirectories = [await getDownloadsDirectory()];
    }

    List<StorageInfo> storageInfoList = [];

    if (externalDirectories != null && externalDirectories.isNotEmpty) {
      for (var dir in externalDirectories) {
        var availableMegaBytes =
            (await DiskSpacePlus().getFreeDiskSpaceForPath(dir!.path)) ?? 0.0;

        if (dir.path.contains('s.s.saturn')) {
          //Skip app internal storage
          continue;
        }

        storageInfoList.add(
          StorageInfo(
            rootDir: dir.path,
            appFilesDir: dir.path,
            availableBytes: availableMegaBytes > 0
                ? (availableMegaBytes * 1000000).floor()
                : 0,
          ),
        );
      }
    }

    return storageInfoList;
  }
}

class DirectoryPicker extends StatefulWidget {
  final String initialPath;
  final Function onSelect;
  const DirectoryPicker(this.initialPath, {required this.onSelect, super.key});

  @override
  _DirectoryPickerState createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<DirectoryPicker> {
  late String _path;
  String? _previous;
  String? _root;

  // Alternative Native file picker, not skinned
  // DirectoryLocation? _pickedDirectory;
  // Future<bool> _isPickDirectorySupported = FlutterFileDialog.isPickDirectorySupported();

  @override
  void initState() {
    _path = widget.initialPath;
    super.initState();
  }

  Future _resetPath() async {
    final appFilesDir = await getApplicationDocumentsDirectory();
    setState(() => _path = appFilesDir.path);
  }

  /*Future<void> _pickDirectory() async {
    _pickedDirectory = (await FlutterFileDialog.pickDirectory());
    setState(() {});
  }*/

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Pick-a-Path'.i18n,
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.sd_card, semanticLabel: 'Select storage'.i18n),
            onPressed: () {
              //_pickDirectory();
              //Chose storage
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('Select storage'.i18n),
                    content: FutureBuilder(
                      future: getStorageInfo(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) return const ErrorScreen();
                        if (!snapshot.hasData) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                CircularProgressIndicator(
                                  color: Theme.of(context).primaryColor,
                                ),
                              ],
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ...List.generate(snapshot.data?.length ?? 0, (i) {
                              StorageInfo si = snapshot.data![i];
                              return ListTile(
                                title: Text(si.rootDir),
                                leading: const Icon(Icons.sd_card),
                                trailing: Text(filesize(si.availableBytes)),
                                onTap: () {
                                  setState(() {
                                    _path = si.appFilesDir;
                                    _root = si.rootDir;
                                    if (i != 0) _root = si.appFilesDir;
                                  });
                                  Navigator.of(context).pop();
                                },
                              );
                            }),
                          ],
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.done),
        onPressed: () {
          //When folder confirmed
          widget.onSelect(_path);
          Navigator.of(context).pop();
        },
      ),
      body: FutureBuilder(
        future: Directory(_path).list().toList(),
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          //On error go to last good path
          if (snapshot.hasError) {
            Future.delayed(const Duration(milliseconds: 50), () {
              if (_previous == null) {
                _resetPath();
                return;
              }
              setState(() => _path = _previous!);
            });
          }
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            );
          }

          List<FileSystemEntity> data = snapshot.data;
          return ListView(
            children: <Widget>[
              ListTile(title: Text(_path)),
              ListTile(
                title: Text('Go up'.i18n),
                leading: const Icon(Icons.arrow_upward),
                onTap: () {
                  setState(() {
                    if (_root == _path) {
                      Fluttertoast.showToast(
                        msg: 'Permission denied'.i18n,
                        gravity: ToastGravity.BOTTOM,
                      );
                      return;
                    }
                    _previous = _path;
                    _path = Directory(_path).parent.path;
                  });
                },
              ),
              ...List.generate(data.length, (i) {
                FileSystemEntity f = data[i];
                if (f is Directory) {
                  return ListTile(
                    title: Text(f.path.split('/').last),
                    leading: const Icon(Icons.folder),
                    onTap: () {
                      setState(() {
                        _previous = _path;
                        _path = f.path;
                      });
                    },
                  );
                }
                return const SizedBox(height: 0, width: 0);
              }),
            ],
          );
        },
      ),
    );
  }
}

class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});

  @override
  _CreditsScreenState createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  String _version = '';

  // static final List<List<String>> translators = [
  //   ['Xandar Null', 'Arabic'],
  //   ['Markus', 'German'],
  //   ['Andrea', 'Italian'],
  //   ['Diego Hiro', 'Portuguese'],
  //   ['Orfej', 'Russian'],
  //   ['Chino Pacia', 'Filipino'],
  //   ['ArcherDelta & PetFix', 'Spanish'],
  //   ['Shazzaam', 'Croatian'],
  //   ['VIRGIN_KLM', 'Greek'],
  //   ['koreezzz', 'Korean'],
  //   ['Fwwwwwwwwwweze', 'French'],
  //   ['kobyrevah', 'Hebrew'],
  //   ['HoScHaKaL', 'Turkish'],
  //   ['MicroMihai', 'Romanian'],
  //   ['LenteraMalam', 'Indonesian'],
  //   ['RTWO2', 'Persian']
  // ];

  @override
  void initState() {
    PackageInfo.fromPlatform().then((info) {
      setState(() {
        _version = 'v${info.version}';
      });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('About'.i18n),
      body: ListView(
        children: [
          const FreezerTitle(),
          Text(
            _version,
            textAlign: TextAlign.center,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
          const FreezerDivider(),
          ListTile(
            title: Text('Telegram Channel'.i18n),
            subtitle: Text('To get latest releases'.i18n),
            leading: const Icon(
              FontAwesome5.telegram,
              color: Color(0xFF27A2DF),
              size: 36.0,
            ),
            onTap: () {
              launchUrlString('https://t.me/SaturnReleases');
            },
          ),
          ListTile(
            title: Text('Telegram Group'.i18n),
            subtitle: Text('Official chat'.i18n),
            leading: const Icon(
              FontAwesome5.telegram,
              color: Colors.cyan,
              size: 36.0,
            ),
            onTap: () {
              launchUrlString('https://t.me/SaturnDiscuss');
            },
          ),
          ListTile(
            title: Text('Discord'.i18n),
            subtitle: Text('Official Discord server'.i18n),
            leading: const Icon(
              FontAwesome5.discord,
              color: Color(0xff7289da),
              size: 36.0,
            ),
            onTap: () {
              launchUrlString('https://saturn.kim/discord');
            },
          ),
          ListTile(
            title: Text('Repository'.i18n),
            subtitle: Text('Source code, report issues there.'.i18n),
            leading: const Icon(Icons.code, color: Colors.green, size: 36.0),
            onTap: () {
              launchUrlString('https://github.com/Sheathed/Saturn');
            },
          ),
          ListTile(
            title: const Text('Donate'),
            subtitle: const Text(
              'Send crypto to the Saturn fund to support the development.',
            ),
            leading: const Icon(
              FontAwesome5.bitcoin,
              color: Color.fromRGBO(247, 147, 26, 58),
              size: 36.0,
            ),
            onTap: () {
              launchUrlString('https://fund.saturn.kim/');
            },
          ),
          const FreezerDivider(),
          ListTile(
            title: const Text('bw86'),
            subtitle: const Text('Logo Designer, Developer'),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('Visit my site!'.i18n),
                    content: Text('www.autow.in'.i18n),
                    actions: <Widget>[
                      TextButton(
                        style: ButtonStyle(
                          foregroundColor: WidgetStateProperty.all<Color>(
                            Theme.of(context).primaryColor,
                          ),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('AGREE'.i18n),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          ListTile(
            title: const Text('Matt'),
            subtitle: const Text('Developer'),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: Text('hiya!! please star the repo'.i18n),
                    content: Text('github.com/Sheathed'.i18n),
                    actions: <Widget>[
                      TextButton(
                        style: ButtonStyle(
                          foregroundColor: WidgetStateProperty.all<Color>(
                            Theme.of(context).primaryColor,
                          ),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('AGREE'.i18n),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          const ListTile(
            title: Text('ettex, Xander Null, Francesco, Tobs'),
            subtitle: Text('Original Freezer App'),
          ),
          ListTile(
            title: const Text('Open-Source Licenses & Libraries'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const LicensesScreen()),
            ),
          ),
          const FreezerDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
            child: Text(
              'Huge thanks to all the contributors! <3'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.0),
            ),
          ),
          const FreezerDivider(),
        ],
      ),
    );
  }
}

class LicensesScreen extends StatefulWidget {
  const LicensesScreen({super.key});

  @override
  _LicensesScreenState createState() => _LicensesScreenState();
}

class _LicensesScreenState extends State<LicensesScreen> {
  // Each entry: [packages, shortSubtitle, fullLicenseText]
  static final List<List<String>> licenses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLicenses();
  }

  // Load licenses from Flutter's LicenseRegistry and populate `licenses`.
  // We collect package names (comma-separated), a short subtitle (first line)
  // and the full license text for the detail view.
  Future<void> _loadLicenses() async {
    // Don't reload if already loaded
    if (licenses.isNotEmpty) return;

    final List<List<String>> loaded = [];

    try {
      // Group by package name (normalized) -> collect distinct license texts and
      // original package name variants for display.
      final Map<String, Set<String>> pkgToTexts = {};
      final Map<String, Set<String>> pkgToDisplayNames = {};

      String normalizePkg(String pkg) {
        var n = pkg.trim();
        if (n.contains('/')) n = n.split('/').last;
        if (n.contains(':')) n = n.split(':').last;
        return n.toLowerCase();
      }

      await LicenseRegistry.licenses.forEach((LicenseEntry entry) {
        // Build full text from paragraphs and normalize whitespace
        final List<String> parts = entry.paragraphs
            .map((p) => p.text.trim())
            .where((t) => t.isNotEmpty)
            .toList();
        if (parts.isEmpty) return;
        final String fullText = parts.join('\n\n').trim();

        for (final pkg in entry.packages) {
          final String key = normalizePkg(pkg);
          pkgToTexts.putIfAbsent(key, () => <String>{});
          pkgToDisplayNames.putIfAbsent(key, () => <String>{});
          pkgToTexts[key]!.add(fullText);
          pkgToDisplayNames[key]!.add(pkg.trim());
        }
      });

      // Heuristic grouping: compute token frequencies from all display names
      // (split on non-alphanumerics) and prefer tokens that appear across
      // multiple packages (eg. 'accessibility'). This lets us group related
      // packages by a common name fragment.
      final Map<String, int> tokenFreq = {};
      final RegExp splitter = RegExp(r'[^A-Za-z0-9]+');

      for (final names in pkgToDisplayNames.values) {
        for (final name in names) {
          final tokens = name
              .split(splitter)
              .map((t) => t.toLowerCase())
              .where((t) => t.length >= 4)
              .toSet();
          for (final t in tokens) {
            tokenFreq[t] = (tokenFreq[t] ?? 0) + 1;
          }
        }
      }

      // For each package key, pick the best grouping token (highest global freq)
      // from its display names. If none found, fall back to the normalized key.
      final Map<String, Set<String>> groupKeyToPkgs = {};
      final Map<String, Set<String>> groupKeyToTexts = {};

      for (final key in pkgToDisplayNames.keys) {
        final names = pkgToDisplayNames[key]!.toList();
        String? bestToken;
        int bestScore = 0;
        for (final name in names) {
          final tokens = name
              .split(splitter)
              .map((t) => t.toLowerCase())
              .where((t) => t.length >= 4);
          for (final t in tokens) {
            final score = tokenFreq[t] ?? 0;
            if (score > bestScore ||
                (score == bestScore &&
                    (bestToken == null || t.length > bestToken.length))) {
              bestToken = t;
              bestScore = score;
            }
          }
        }

        // Determine group key
        final String groupKey = (bestToken != null && bestScore > 1)
            ? bestToken
            : key;

        groupKeyToPkgs.putIfAbsent(groupKey, () => <String>{});
        groupKeyToPkgs[groupKey]!.addAll(pkgToDisplayNames[key]!);

        groupKeyToTexts.putIfAbsent(groupKey, () => <String>{});
        groupKeyToTexts[groupKey]!.addAll(pkgToTexts[key]!);
      }

      // Build loaded entries from groups
      for (final groupKey in groupKeyToPkgs.keys) {
        final displayNames = groupKeyToPkgs[groupKey]!.toList()..sort();
        final title = displayNames.join(', ');

        final texts = groupKeyToTexts[groupKey]!.toList();
        String subtitle;
        String content;
        if (texts.isEmpty) {
          subtitle = 'License'.i18n;
          content = '';
        } else if (texts.length == 1) {
          content = texts.first;
          subtitle = content.split('\n').first.trim();
        } else {
          final sb = StringBuffer();
          for (var i = 0; i < texts.length; i++) {
            sb.writeln('----- License ${i + 1} -----');
            sb.writeln(texts[i]);
            sb.writeln();
          }
          content = sb.toString().trim();
          subtitle = 'Multiple licenses (${texts.length})';
        }

        loaded.add([title, subtitle, content]);
      }
    } catch (e) {
      // If something goes wrong, add a small fallback entry
      loaded.add(['unknown', 'Failed to load licenses', 'Error: $e']);
    }

    if (mounted) {
      setState(() {
        licenses.clear();
        licenses.addAll(loaded);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Open-Source Licenses & Libs'.i18n),
      body: _loading && licenses.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 12.0),
                  Text('Loading licenses...'.i18n),
                ],
              ),
            )
          : ListView(
              children: [
                ...List.generate(
                  licenses.length,
                  (i) => ListTile(
                    title: Text(licenses[i][0]),
                    subtitle: Text(licenses[i][1]),
                    onTap: () {
                      // Show the full license text on tap
                      if (context.mounted) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => LicenseDetail(
                              title: licenses[i][0],
                              content: licenses[i][2],
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                  child: Text(
                    'Huge thanks to all contributors! <3'.i18n,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16.0),
                  ),
                ),
              ],
            ),
    );
  }
}
