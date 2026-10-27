import 'dart:io';

typedef EnvironmentGenerator = Future<int> Function(Directory project);

const _requiredKeys = ['deezerClientId', 'deezerClientSecret'];

class EnvPreparationException implements Exception {
  const EnvPreparationException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<void> main() async {
  try {
    await prepareEnvironment(
      project: Directory.current,
      environmentFile: Platform.environment['ENV_FILE'],
    );
    stdout.writeln('Generated lib/utils/env.g.dart with Envied.');
  } on EnvPreparationException catch (error) {
    stderr.writeln('::error::${error.message}');
    exitCode = 1;
  }
}

/// Builds the generated part from the dotenv secret instead of trusting a
/// second, potentially stale or missing, pre-generated Dart secret.
Future<void> prepareEnvironment({
  required Directory project,
  required String? environmentFile,
  EnvironmentGenerator? generate,
}) async {
  if (environmentFile == null || environmentFile.trim().isEmpty) {
    throw const EnvPreparationException(
      'The env secret is missing or empty. Set secrets.env in the workflow '
      'environment to dotenv content containing deezerClientId and '
      'deezerClientSecret.',
    );
  }

  final content = environmentFile
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  for (final key in _requiredKeys) {
    final match = RegExp(
      '^\\s*(?:export\\s+)?$key\\s*=([^\\n]*)',
      multiLine: true,
    ).firstMatch(content);
    if (match == null || !_hasValue(match.group(1)!)) {
      throw EnvPreparationException(
        'The env secret must contain a non-empty $key dotenv entry.',
      );
    }
  }

  final source = File.fromUri(project.uri.resolve('lib/utils/env.dart'));
  if (!await source.exists()) {
    throw const EnvPreparationException(
      'Run this command from the repository root (lib/utils/env.dart is missing).',
    );
  }
  await File.fromUri(project.uri.resolve('lib/.env')).writeAsString(content);

  final result = await (generate ?? _generateEnvironment)(project);
  if (result != 0) {
    throw EnvPreparationException(
      'Envied generation failed (exit $result). Check the env secret dotenv '
      'syntax and run flutter pub get before preparing the build.',
    );
  }

  final generated = File.fromUri(project.uri.resolve('lib/utils/env.g.dart'));
  final output = await generated.exists() ? await generated.readAsString() : '';
  final hasPart = RegExp(
    '''part\\s+of\\s+['"]env\\.dart['"]\\s*;''',
  ).hasMatch(output);
  if (!hasPart ||
      !RegExp(r'\bclass\s+_Env\b').hasMatch(output) ||
      _requiredKeys.any((key) => !RegExp('\\b$key\\b').hasMatch(output))) {
    throw const EnvPreparationException(
      'Envied did not generate a valid lib/utils/env.g.dart part. '
      'The build has been stopped before native compilation.',
    );
  }
}

bool _hasValue(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.startsWith('#')) return false;
  final quote = value[0];
  if (quote != '"' && quote != "'") {
    return value.split('#').first.trim().isNotEmpty;
  }
  for (var i = 1; i < value.length; i++) {
    if (value[i] == '\\' && quote == '"') {
      i++;
    } else if (value[i] == quote) {
      return value.substring(1, i).trim().isNotEmpty;
    }
  }
  return false;
}

Future<int> _generateEnvironment(Directory project) async {
  // Capture generator output because diagnostics can include source snippets or
  // dotenv values. Only the exit status is safe to publish in CI logs.
  final result = await Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'run',
    'build_runner',
    'build',
    '--build-filter=lib/utils/env.g.dart',
  ], workingDirectory: project.path);
  return result.exitCode;
}
