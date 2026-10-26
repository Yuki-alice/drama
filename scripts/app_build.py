from dataclasses import dataclass


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
        return '-s -w'
