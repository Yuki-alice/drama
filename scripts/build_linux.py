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
parser = argparse.ArgumentParser(description='构建红果鉴 Linux 应用')
options = parser.parse_args()
if platform.system() != 'Linux':
    raise SystemExit('Linux 应用需要在 Linux 上构建。')
if platform.machine().lower() not in ('x86_64', 'amd64'):
    raise SystemExit('当前 FFmpegKit Linux 依赖仅支持 x86_64；arm64 需先替换 FFmpegKit。')
for package in ('gtk+-3.0', 'mpv'):
    if subprocess.run(['pkg-config', '--exists', package]).returncode != 0:
        raise SystemExit(f'缺少系统依赖 {package}；请安装 libgtk-3-dev / libmpv-dev。')
variant = BuildVariant()
env = os.environ.copy()
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')

subprocess.run(
    [sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'linux', *variant.arguments],
    cwd=root,
    env=env,
    check=True,
)
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=env, check=True)
subprocess.run(
    [flutter, 'build', 'linux', '--release', '--no-pub', *variant.flutter_arguments],
    cwd=root,
    env=env,
    check=True,
)
arch = 'x64'
bundle = root / 'build' / 'linux' / arch / 'release' / 'bundle'
core = bundle / 'lib' / 'libduanju_core.so'
if not core.is_file() or core.stat().st_size == 0:
    raise SystemExit('Linux 应用包缺少原生核心 lib/libduanju_core.so。')

match = re.search(r'^version:\s*([\w.+-]+)\s*$', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
if not match:
    raise SystemExit('pubspec.yaml 缺少合法版本号。')
version = match.group(1)
output = root / 'dist' / 'linux'
output.mkdir(parents=True, exist_ok=True)
artifact = output / f'{variant.slug}-{version}-linux-{arch}.tar.gz'
subprocess.run(
    ['tar', '--create', '--gzip', '--file', str(artifact), '-C', str(bundle), '.'],
    cwd=root,
    check=True,
)
print(artifact)
