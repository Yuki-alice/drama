#!/usr/bin/env python3
"""校验单文件扩展并生成官方索引 index.json。

用法：
  python3 tools/build.py --check
  python3 tools/build.py --base-url https://raw.githubusercontent.com/OWNER/REPO/main/extensions

扩展是 extensions/<id>.js，元数据写在文件头注释里；index.json 只是
校验后的清单，不再打包 zip，也不做签名。
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTENSIONS = ROOT / "extensions"
DEFAULT_BASE_URL = "https://raw.githubusercontent.com/hongguojian/hongguojian-extensions/main/extensions"

HEADER_RE = re.compile(r"// ==HongguoExtension==(.*?)// ==/HongguoExtension==", re.S)
FIELD_RE = re.compile(r"^\s*//\s*@(\w+)\s*(.*)$")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,31}$")
VERSION_RE = re.compile(r"^[0-9a-z.+-]{1,32}$")

FIELD_MAP = {
    "id": "id",
    "name": "name",
    "version": "version",
    "apilevel": "apiLevel",
    "restricted": "restricted",
    "description": "description",
    "group": "group",
    "groupname": "groupName",
    "entryname": "entryName",
    "onlinesearch": "onlineSearch",
    "pagedsearch": "pagedSearch",
    "suggestions": "suggestions",
    "minapp": "minApp",
}
BOOL_FIELDS = {"restricted", "onlineSearch", "pagedSearch", "suggestions"}


def fail(message: str) -> None:
    raise SystemExit(message)


def parse_manifest(path: Path) -> tuple[dict, str]:
    source = path.read_text(encoding="utf-8")
    if len(source.encode("utf-8")) > 512 * 1024:
        fail(f"{path}: 超过 512 KiB 上限")
    match = HEADER_RE.search(source)
    if not match:
        fail(f"{path}: 缺少 ==HongguoExtension== 头部")
    fields = {}
    for line in match.group(1).splitlines():
        parsed = FIELD_RE.match(line.strip())
        if not parsed:
            continue
        key = parsed.group(1).lower()
        if key in FIELD_MAP:
            fields[FIELD_MAP[key]] = parsed.group(2).strip()
    manifest = {"apiLevel": 1}
    for key in ("id", "name", "version"):
        if not fields.get(key):
            fail(f"{path}: 头部缺少 @{key}")
        manifest[key] = fields[key]
    if fields.get("apiLevel"):
        try:
            manifest["apiLevel"] = int(fields["apiLevel"])
        except ValueError:
            fail(f"{path}: @apiLevel 不是整数")
    for key in BOOL_FIELDS:
        if fields.get(key, "").lower() in ("true", "1", "yes"):
            manifest[key] = True
    for key in ("description", "group", "groupName", "entryName", "minApp"):
        if fields.get(key):
            manifest[key] = fields[key]
    if not ID_RE.fullmatch(manifest["id"]):
        fail(f"{path}: id 必须是 2–32 位小写字母、数字或连字符")
    if manifest["id"] != path.stem:
        fail(f"{path}: 文件名必须与 id 一致")
    if not VERSION_RE.fullmatch(manifest["version"]):
        fail(f"{path}: 版本号无效")
    if manifest["apiLevel"] < 1 or manifest["apiLevel"] > 1:
        fail(f"{path}: apiLevel 超出宿主支持范围")
    if len(manifest["name"]) > 24:
        fail(f"{path}: name 不能超过 24 个字")
    if len(manifest.get("description", "")) > 48:
        fail(f"{path}: description 不能超过 48 个字")
    for key, limit in (("group", 32), ("groupName", 24), ("entryName", 16)):
        if len(manifest.get(key, "")) > limit:
            fail(f"{path}: {key} 不能超过 {limit} 个字")
    if manifest.get("groupName") and not manifest.get("group"):
        fail(f"{path}: groupName 需要同时声明 group")
    check_syntax(path, source)
    return manifest, source


def check_syntax(path: Path, source: str) -> None:
    """node 可用时做一次语法预检；不可用则交给应用侧编译把关。"""
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as handle:
            handle.write(source)
            temporary = handle.name
        try:
            subprocess.run(["node", "--check", temporary], check=True, capture_output=True)
        finally:
            Path(temporary).unlink(missing_ok=True)
    except FileNotFoundError:
        pass
    except subprocess.CalledProcessError as error:
        fail(f"{path}: JavaScript 语法错误\n{error.stderr.decode('utf-8', 'replace')}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只校验，不生成索引")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="index.json 中的扩展下载地址前缀")
    args = parser.parse_args()

    files = sorted(EXTENSIONS.glob("*.js"))
    if not files:
        fail("extensions/ 下没有扩展脚本")
    manifests = []
    for path in files:
        manifest, _ = parse_manifest(path)
        manifests.append((path, manifest))
        print(f"OK {manifest['id']} v{manifest['version']}")
    if args.check:
        return

    base_url = args.base_url.rstrip("/")
    entries = []
    for path, manifest in manifests:
        entry = dict(manifest)
        entry["url"] = f"{base_url}/{path.name}"
        entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        entry["changelog"] = "官方扩展源"
        entries.append(entry)
    (ROOT / "index.json").write_text(
        json.dumps(entries, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"写入 index.json（{len(entries)} 项）")


if __name__ == "__main__":
    main()
