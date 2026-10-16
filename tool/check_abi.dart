import 'dart:io';

/// C ABI 一致性门禁（轻量，无需 LLVM）。
///
/// 校验 `rust/core/drama_core.h` 导出的符号集合与
/// `lib/data/services/drama_core_bindings.dart` 手写 `@Native` 绑定一致：
/// 头文件增删符号而手写绑定未同步时失败。
/// 完整的 ffigen 签名校对仍走人工流程（见 `ffigen.yaml` 注释，需 libclang）。
///
/// 必须在仓库根执行。
Future<void> main() async {
  final header = File('rust/core/drama_core.h').readAsStringSync();
  final bindings = File(
    'lib/data/services/drama_core_bindings.dart',
  ).readAsStringSync();

  final headerSymbols = RegExp(
    r'\bdrama_[A-Za-z0-9_]+\b',
  ).allMatches(header).map((m) => m.group(0)!).toSet();
  final bindingSymbols = RegExp(
    r"symbol:\s*'([^']+)'",
  ).allMatches(bindings).map((m) => m.group(1)!).toSet();

  var ok = true;
  for (final s in headerSymbols) {
    if (!bindingSymbols.contains(s)) {
      stderr.writeln('missing binding for C symbol: $s');
      ok = false;
    }
  }
  for (final s in bindingSymbols) {
    if (!headerSymbols.contains(s)) {
      stderr.writeln('binding without C declaration: $s');
      ok = false;
    }
  }
  if (!bindings.contains('@Native')) {
    stderr.writeln('bindings must use @Native form (native assets)');
    ok = false;
  }
  if (ok) {
    stdout.writeln(
      'ABI symbols in sync: ${headerSymbols.toList()..sort()}',
    );
  } else {
    exit(1);
  }
}
