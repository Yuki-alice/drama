import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Rust 原生资源构建钩子（原生分发 / 目录结构）。
///
/// 把仓库根目录的 `rust/core`（与本 Dart 包同仓）编译为 Dart code asset。
/// - `cratePath` 相对本 Dart 包根（仓库根）解析。
/// - `assetName` 必须与承载 `@Native` 绑定的 Dart 文件路径一致
///   （文件 `lib/data/services/drama_core_bindings.dart` → 资源名 `data/services/...`）。
/// - 依赖源镜像见仓库根 `.cargo/config.toml`。
///
/// **必须先判 `buildCodeAssets`**：hook 不只在「编译 code asset」时被调用，
/// SDK 也会用**空 `build_asset_types`** 调一次（依赖发现/图构建阶段）。
/// 此时 `input.config.code` 会直接抛
/// `Bad state: HookConfig.code should only be accessed when building code assets`，
/// 表现为 `Building native assets failed. build.dart returned with exit code: 255`。
void main(List<String> args) async {
  await build(args, (input, output) async {
    // 非 code asset 构建阶段：本 hook 无事可做，直接返回（不能读 input.config.code）。
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;

    // Windows 原生库仅打包 x64：arm64 直接 FATAL，避免产出无法加载的库。
    if (code.targetOS == OS.windows &&
        code.targetArchitecture != Architecture.x64) {
      throw UnsupportedError(
        'Windows ${code.targetArchitecture} 原生库不受支持：MVP 仅打包 x64。',
      );
    }

    await RustBuilder(
      assetName: 'data/services/drama_core_bindings.dart',
      cratePath: 'rust/core',
    ).run(input: input, output: output);
  });
}
