import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'analyzer.dart';
import 'models.dart';

/// Runs the Flutternaut generator CLI with the given [arguments].
///
/// Shared entry point for both `flutternaut_generator` and the
/// `flutternaut` wrapper CLI.
void runFlutternautCli(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('output',
        abbr: 'o', help: 'Output file path (overrides pubspec config).')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final results = parser.parse(arguments);

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final projectPath = results.rest.isEmpty
      ? Directory.current.path
      : p.normalize(p.absolute(results.rest.first));

  final projectDir = Directory(projectPath);
  if (!projectDir.existsSync()) {
    stderr.writeln('Error: Directory not found: $projectPath');
    exit(1);
  }

  final libDir = Directory(p.join(projectPath, 'lib'));
  if (!libDir.existsSync()) {
    stderr.writeln('Error: No lib/ directory found in $projectPath');
    exit(1);
  }

  final pubspec = _readPubspec(File(p.join(projectPath, 'pubspec.yaml')));
  final outputPath =
      results['output'] as String? ?? pubspec.output ?? 'flutternaut_keys.json';

  final views = FlutternautAnalyzer().scanDirectory(projectPath);

  final output = KeysOutput(
    generatedAt: DateTime.now(),
    package: pubspec.name,
    views: views,
  );

  final outputFile = File(
      p.isAbsolute(outputPath) ? outputPath : p.join(projectPath, outputPath));
  if (!outputFile.parent.existsSync()) {
    outputFile.parent.createSync(recursive: true);
  }
  outputFile.writeAsStringSync(output.toJsonString());

  final totalRows = views.values.fold<int>(0, (sum, v) => sum + v.rows.length);
  final totalElements =
      views.values.fold<int>(0, (sum, v) => sum + v.elements.length);
  stdout.writeln(
    'Found ${views.length} view(s), $totalRows row(s), $totalElements element(s).',
  );
  stdout.writeln('Output: ${outputFile.path}');
}

class _PubspecConfig {
  final String name;
  final String? output;
  const _PubspecConfig({required this.name, this.output});
}

_PubspecConfig _readPubspec(File pubspecFile) {
  if (!pubspecFile.existsSync()) {
    return const _PubspecConfig(name: 'unknown');
  }

  final yaml = loadYaml(pubspecFile.readAsStringSync());
  if (yaml is! YamlMap) {
    return const _PubspecConfig(name: 'unknown');
  }

  final name = yaml['name']?.toString() ?? 'unknown';

  String? output;
  final config = yaml['flutternaut'] ?? yaml['flutternaut_generator'];
  if (config is YamlMap) {
    output = config['output']?.toString();
  }

  return _PubspecConfig(name: name, output: output);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Usage: dart run flutternaut_generator [options] [project_path]');
  stdout.writeln();
  stdout.writeln('Scans a Flutter project for `@FlutternautView`-annotated screens');
  stdout.writeln('and the `ValueKey` literals inside them, then writes a structured');
  stdout.writeln('JSON file grouped by view (with list-row members detected).');
  stdout.writeln();
  stdout.writeln('Configure the output path in your pubspec.yaml:');
  stdout.writeln();
  stdout.writeln('  flutternaut:');
  stdout.writeln('    output: lib/generated/flutternaut_keys.json');
  stdout.writeln();
  stdout.writeln('(the legacy `flutternaut_generator:` key is still read as a fallback)');
  stdout.writeln();
  stdout.writeln(parser.usage);
}
