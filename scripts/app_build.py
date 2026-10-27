import os
from dataclasses import dataclass

# 扩展仓库索引地址：发布时用环境变量覆盖，无需改代码。
# 未设置时保持 Go 侧的内置默认值（占位地址，客户端会跳过远程索引）。
EXTENSION_INDEX_ENV = 'HONGGUO_EXTENSION_INDEX_URL'


def extension_index_flag():
    """返回覆盖 core.extensionIndexURL 的 ldflags 片段。

    走链接参数而不是配置文件：这个地址属于"这个包从哪来"的构建元数据，
    不该在运行期被用户或扩展改写。
    """
    url = os.environ.get(EXTENSION_INDEX_ENV, '').strip()
    if not url:
        return ''
    if not url.startswith(('http://', 'https://')):
        raise SystemExit(f'{EXTENSION_INDEX_ENV} 必须是 http(s) 地址：{url}')
    if '"' in url or "'" in url or ' ' in url:
        raise SystemExit(f'{EXTENSION_INDEX_ENV} 不能包含空格或引号：{url}')
    return f"-X 'duanjuapp/native/core.extensionIndexURL={url}'"


@dataclass(frozen=True)
class BuildVariant:
    """单包化后只有一种构建变体：全部内置站源 + 可安装扩展。"""

    @property
    def slug(self):
        return 'hongguojian'

    @property
    def arguments(self):
        return []

    @property
    def flutter_arguments(self):
        return []

    @property
    def linker_flags(self):
        index = extension_index_flag()
        return f'-s -w {index}' if index else '-s -w'
