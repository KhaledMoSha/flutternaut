import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'package:flutternaut_generator/flutternaut_generator.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('output',
        abbr: 'o', help: 'Output file path (overrides pubspec config).')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final results = parser.parse(arguments);

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  // The project directory is the first positional arg, or current dir
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

  // Read pubspec.yaml
  final pubspecFile = File(p.join(projectPath, 'pubspec.yaml'));
  final pubspec = _readPubspec(pubspecFile);
  final packageName = pubspec.name;

  // Resolve output path: CLI flag > pubspec config > default
  final outputPath =
      results['output'] as String? ?? pubspec.output ?? 'flutternaut_keys.json';

  // Scan
  final analyzer = FlutternautAnalyzer();
  final elements = analyzer.scanDirectory(projectPath);

  // Build output
  final output = KeysOutput(
    generatedAt: DateTime.now(),
    package: packageName,
    elements: elements,
  );

  // Write
  final outputFile = File(
      p.isAbsolute(outputPath) ? outputPath : p.join(projectPath, outputPath));

  // Create parent directories if needed
  final parentDir = outputFile.parent;
  if (!parentDir.existsSync()) {
    parentDir.createSync(recursive: true);
  }

  outputFile.writeAsStringSync(output.toJsonString());

  stdout.writeln('Found ${elements.length} elements.');
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

  final content = pubspecFile.readAsStringSync();
  final yaml = loadYaml(content);

  if (yaml is! YamlMap) {
    return const _PubspecConfig(name: 'unknown');
  }

  final name = yaml['name']?.toString() ?? 'unknown';

  // Read flutternaut_generator config section
  String? output;
  final config = yaml['flutternaut_generator'];
  if (config is YamlMap) {
    output = config['output']?.toString();
  }

  return _PubspecConfig(name: name, output: output);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Usage: flutternaut_generator [options] [project_path]');
  stdout.writeln();
  stdout.writeln('Scans a Flutter project for Flutternaut widgets and');
  stdout.writeln('extracts labels into flutternaut_keys.json.');
  stdout.writeln();
  stdout.writeln('Configure output path in pubspec.yaml:');
  stdout.writeln();
  stdout.writeln('  flutternaut_generator:');
  stdout.writeln('    output: custom/path/keys.json');
  stdout.writeln();
  stdout.writeln(parser.usage);
}
