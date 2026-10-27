#!/usr/bin/env python3
"""把 extensions-repo 准备成可推送的独立仓库，并打印后续手动步骤。

用法：
  python3 tools/prepare_release.py --repo OWNER/REPO [--branch main]

它会：
  1. 用目标地址重新生成 index.json（含 SHA-256）；
  2. 校验所有扩展；
  3. 在 extensions-repo 内初始化独立 git 仓库并提交；
  4. 打印推送命令与需要设置的构建环境变量。

真正创建 GitHub 仓库、推送、以及打 tag 属于仓库所有者的操作，
脚本只做本地准备，不会联网。
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'tools' / 'build.py'


def run(arguments, cwd):
    print('$ ' + ' '.join(arguments), flush=True)
    subprocess.run(arguments, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True, help='GitHub 仓库，形如 OWNER/REPO')
    parser.add_argument('--branch', default='main')
    parser.add_argument('--skip-git', action='store_true', help='只生成索引，不初始化仓库')
    args = parser.parse_args()

    if '/' not in args.repo or args.repo.count('/') != 1:
        raise SystemExit('--repo 需要形如 OWNER/REPO')

    media = (
        f'https://raw.githubusercontent.com/{args.repo}/{args.branch}/extensions'
    )
    # index.json 与 extensions/ 同级；构建参数要的是索引文件的完整地址。
    index_url = f'{media.rsplit("/", 1)[0]}/index.json'

    # 1) 用真实地址重建索引（同时完成校验）。
    run([sys.executable, str(BUILD), '--base-url', media], cwd=ROOT)

    index = ROOT / 'index.json'
    if not index.exists():
        raise SystemExit('索引生成失败')
    print(f'\n已生成 {index.relative_to(ROOT)}，脚本下载前缀：{media}')

    if args.skip_git:
        return

    # 2) 独立仓库（extensions-repo 位于主仓库内，需要自己的 .git）。
    if not (ROOT / '.git').exists():
        run(['git', 'init', '-b', args.branch], cwd=ROOT)

    ignore = ROOT / '.gitignore'
    if not ignore.exists():
        ignore.write_text('__pycache__/\n*.pyc\n', encoding='utf-8')

    run(['git', 'add', '-A'], cwd=ROOT)
    staged = subprocess.run(
        ['git', 'diff', '--cached', '--name-only'],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()
    if staged:
        run(['git', 'commit', '-m', 'release: 更新扩展索引'], cwd=ROOT)
    else:
        print('没有需要提交的改动。')

    print('\n' + '=' * 60)
    print('接下来需要你手动完成：')
    print(f'  1. 在 GitHub 创建仓库 {args.repo}（公开，勿初始化 README）')
    print(f'  2. cd {ROOT}')
    print(f'     git remote add origin https://github.com/{args.repo}.git')
    print(f'     git push -u origin {args.branch}')
    print('  3. 构建时告诉打包脚本索引地址：')
    print(f'     export HONGGUO_EXTENSION_INDEX_URL={index_url}')
    print('=' * 60)


if __name__ == '__main__':
    main()
