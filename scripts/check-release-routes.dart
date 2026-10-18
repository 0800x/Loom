import 'dart:io';

import '../apps/loom/lib/app/dev_surface_policy.dart';

void main() {
  if (loomDevelopmentSurfacesEnabled)
    throw StateError(
      'Compile this check with -Ddart.vm.product=true; development routes must be disabled.',
    );
  for (final name in [
    'apps/loom/lib/app/loom_app.dart',
    'apps/loom/lib/features/onboarding/presentation/welcome_screen.dart',
  ]) {
    final source = File(name).readAsStringSync();
    if (!source.contains('if (loomDevelopmentSurfacesEnabled)') ||
        !source.contains('/design-lab'))
      throw StateError('Release route gate missing in $name');
    if (source.indexOf('if (loomDevelopmentSurfacesEnabled)') >
        source.indexOf("'/design-lab'"))
      throw StateError('Development route appears before its gate in $name');
  }
  stdout.writeln('Release development-route gate is disabled.');
}
