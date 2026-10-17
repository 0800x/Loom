// Run with the application's --packages configuration before native compilation.
import 'dart:io';
import 'package:package_config/package_config.dart';

Future<void> main(List<String> arguments) async {
  final file = File(arguments.single).absolute;
  final config = await loadPackageConfig(file);
  final source = file.parent.uri.resolve('flutter_build/dart_plugin_registrant.dart');
  final expected = Uri.parse('package:loom_generated_registrant/dart_plugin_registrant.dart');
  if (config.toPackageUri(source) != expected || config.resolve(expected) != source) {
    throw StateError('Generated plugin registrant URI does not round-trip');
  }
  stdout.writeln('Generated plugin registrant resolves through a stable package URI');
}
