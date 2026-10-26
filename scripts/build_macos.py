import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import BuildVariant

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='构建红果鉴 macOS 应用')
options = parser.parse_args()
if platform.system() != 'Darwin':
    raise SystemExit('macOS 应用需要在 macOS 上构建。')
variant = BuildVariant()
env = os.environ.copy()
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')

subprocess.run(
    [sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'darwin', *variant.arguments],
    cwd=root,
    env=env,
    check=True,
)
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=env, check=True)
subprocess.run(
    [flutter, 'build', 'macos', '--release', '--no-pub', *variant.flutter_arguments],
    cwd=root,
    env=env,
    check=True,
)

products = root / 'build' / 'macos' / 'Build' / 'Products' / 'Release'
apps = sorted(products.glob('*.app'))
if len(apps) != 1:
    raise SystemExit(f'未能定位 macOS 应用产物：{products}')
app = apps[0]
core = app / 'Contents' / 'MacOS' / 'libduanju_core.dylib'
if not core.is_file() or core.stat().st_size == 0:
    raise SystemExit('macOS 应用缺少原生核心 libduanju_core.dylib。')

match = re.search(r'^version:\s*([\w.+-]+)\s*$', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
if not match:
    raise SystemExit('pubspec.yaml 缺少合法版本号。')
version = match.group(1)
output = root / 'dist' / 'macos'
output.mkdir(parents=True, exist_ok=True)
artifact = output / f'{variant.slug}-{version}-macos-universal.zip'
subprocess.run(
    ['ditto', '-c', '-k', '--keepParent', str(app), str(artifact)],
    cwd=root,
    check=True,
)
print(artifact)
