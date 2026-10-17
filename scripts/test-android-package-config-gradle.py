"""Real Gradle regression: isolate the app from included Flutter tooling builds."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
hook = ROOT / 'scripts/prepare-android-package-config.gradle'
flutter = shutil.which('flutter')
if not flutter:
    raise RuntimeError('Flutter must be on PATH')
sdk = Path(flutter).resolve().parents[1]
wrapper_template = sdk / 'bin/cache/artifacts/gradle_wrapper'
if not (wrapper_template / 'gradlew').is_file():
    raise RuntimeError('Flutter Gradle wrapper cache missing; run flutter precache --android')

with tempfile.TemporaryDirectory(prefix='loom-gradle-init-') as folder:
    root = Path(folder)
    android = root / 'app/android'
    tooling = root / 'tooling/gradle'
    android.mkdir(parents=True)
    tooling.mkdir(parents=True)
    # Use the same cached wrapper Flutter injects, without modifying the SDK.
    shutil.copytree(wrapper_template, android, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'apps/loom/android/gradle/wrapper/gradle-wrapper.properties',
                 android / 'gradle/wrapper/gradle-wrapper.properties')
    wrapper = android / 'gradlew'
    wrapper.chmod(wrapper.stat().st_mode | 0o100)
    app_config = android.parent / '.dart_tool/package_config.json'
    sdk_config = tooling.parent / '.dart_tool/package_config.json'
    app_config.parent.mkdir()
    sdk_config.parent.mkdir()
    app_data = {'configVersion': 2, 'packages': [
        {'name': 'loom_next', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.12'}]}
    app_config.write_text(json.dumps(app_data))
    sdk_config.write_text(json.dumps({'configVersion': 2, 'packages': [
        {'name': 'flutter_tools', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.12'}]}))
    sdk_before = sdk_config.read_bytes()
    (tooling / 'settings.gradle').write_text("rootProject.name='flutter-tooling'\n")
    (tooling / 'build.gradle').write_text('')
    (android / 'settings.gradle').write_text(
        "rootProject.name='loom-hook-proof'\nincludeBuild('../../tooling/gradle') { name = 'flutter-tooling' }\n")
    (android / 'build.gradle').write_text('')
    environment = dict(os.environ, LOOM_ANDROID_PROJECT_DIR=str(android))
    command = [str(wrapper), '--offline', '--no-daemon', '--console=plain',
               '-I', str(hook), '-p', str(android), 'help', ':flutter-tooling:help']

    def run(expected_success):
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=180)
        if (result.returncode == 0) != expected_success:
            raise RuntimeError('Gradle scope regression failed:\n' + (result.stdout + result.stderr)[-6000:])
        return result.stdout + result.stderr

    output = run(True)
    if ':flutter-tooling:help' not in output:
        raise AssertionError('Included tooling build did not execute')
    result = json.loads(app_config.read_text())
    alias = {'name': 'loom_generated_registrant', 'rootUri': 'flutter_build/',
             'packageUri': '', 'languageVersion': '3.12'}
    if result['packages'] != app_data['packages'] + [alias]:
        raise AssertionError('Unexpected application package change')
    if sdk_config.read_bytes() != sdk_before:
        raise AssertionError('Included SDK package configuration was modified')
    first = app_config.read_bytes()
    run(True)
    if app_config.read_bytes() != first:
        raise AssertionError('Settings hook is not idempotent')
    result['packages'][-1]['rootUri'] = 'foreign/'
    app_config.write_text(json.dumps(result))
    conflicting = app_config.read_bytes()
    output = run(False)
    if 'already in use' not in output or app_config.read_bytes() != conflicting:
        raise AssertionError('Alias collision did not fail without mutation')
    if sdk_config.read_bytes() != sdk_before:
        raise AssertionError('Included SDK package configuration was modified')
print('Real Gradle app/included-build scope, idempotence and collision checks passed')
