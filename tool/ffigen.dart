import 'dart:io';

/// 生成 Rust 核心的 Dart FFI 绑定（**校对用**，非构建步骤）。
///
/// 包装 `dart run ffigen --config ffigen.yaml`（配置见仓库根 `ffigen.yaml`）。
/// 需要本机安装 LLVM（提供 libclang）；缺失时该命令会失败。
///
/// ⚠️ 产出的是 `DynamicLibrary.lookup` 风格，**与本项目的 native assets
/// 不兼容**——`lib/data/services/drama_core_bindings.dart` 必须保持手写
/// 的 `@Native` 形式。本入口的用途是：改动 C ABI 后比对生成签名，
/// 再把改动落到手写文件，最后丢弃生成结果。
///
/// 必须在**仓库根**执行（ffigen 相对包根解析 output 与 header 路径）。
Future<void> main() async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'ffigen',
    '--config',
    'ffigen.yaml',
  ], runInShell: true);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exitCode = result.exitCode;
}
