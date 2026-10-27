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
    "vip": "vip",
    "danmaku": "danmaku",
    "detailfields": "detailFields",
    "settings": "settings",
}
BOOL_FIELDS = {"restricted", "onlineSearch", "pagedSearch", "suggestions", "vip", "danmaku"}

# 与 native/ext/manifest.go 的 detailFieldValues 保持一致（统一小写）。
DETAIL_FIELD_VALUES = {
    "vip",
    "heat",
    "views",
    "onlinedate",
    "description",
    "tags",
    "releasestatus",
}
MAX_DETAIL_FIELDS = 6


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
    if fields.get("settings"):
        manifest["settings"] = parse_settings(path, fields["settings"])
    if fields.get("detailFields"):
        parts = [
            part.strip().lower()
            for part in fields["detailFields"].split(",")
            if part.strip()
        ]
        if len(parts) > MAX_DETAIL_FIELDS:
            fail(f"{path}: detailFields 不能超过 {MAX_DETAIL_FIELDS} 个")
        unknown = [part for part in parts if part not in DETAIL_FIELD_VALUES]
        if unknown:
            fail(f"{path}: detailFields 含无效字段 {', '.join(unknown)}")
        if len(set(parts)) != len(parts):
            fail(f"{path}: detailFields 有重复项")
        manifest["detailFields"] = parts
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



SETTING_TYPES = {"input", "toggle", "choice"}
MAX_SETTINGS = 6
BUILTIN_SETTING_KEYS = {"baseURL"}


def parse_settings(path: Path, raw: str) -> list[dict]:
    """校验并解析 @settings 声明（与 native/ext/manifest.go 的 parseSettings 对齐）。"""
    declarations = [item.strip() for item in raw.split(";") if item.strip()]
    if len(declarations) > MAX_SETTINGS:
        fail(f"{path}: 设置项不能超过 {MAX_SETTINGS} 个")
    settings = []
    seen = set()
    for declaration in declarations:
        parts = [part.strip() for part in declaration.split("|")]
        if len(parts) < 3:
            fail(f"{path}: 设置 {declaration!r} 需要至少 key|title|type")
        key, title, kind = parts[0], parts[1], parts[2].lower()
        if not key or key in BUILTIN_SETTING_KEYS:
            fail(f"{path}: 设置 key {key!r} 无效或与内置项冲突")
        if key in seen:
            fail(f"{path}: 设置 key {key!r} 重复")
        seen.add(key)
        if not title:
            fail(f"{path}: 设置 {key!r} 缺少标题")
        if kind not in SETTING_TYPES:
            fail(f"{path}: 设置 {key!r} 类型无效（input / toggle / choice）")
        entry = {"key": key, "title": title, "type": kind}
        if len(parts) > 3 and parts[3]:
            entry["default"] = parts[3]
        # 与 Go 侧对齐：choice 的第 5 段起全是选项，没有 placeholder。
        rest = parts[4:]
        if kind == "choice":
            options = [item for item in rest if item]
            if not 2 <= len(options) <= 12:
                fail(f"{path}: 设置 {key!r} 需要 2–12 个选项")
            parsed = []
            for option in options:
                value, label, found = option.partition("=")
                if not found or not value.strip() or not label.strip():
                    fail(f"{path}: 设置 {key!r} 的选项 {option!r} 需要 value=label")
                parsed.append({"value": value.strip(), "label": label.strip()})
            entry["options"] = parsed
        else:
            if rest and rest[0]:
                entry["placeholder"] = rest[0]
            if len(rest) > 1:
                fail(f"{path}: 设置 {key!r} 只有 choice 类型可以带选项")
        settings.append(entry)
    return settings

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
