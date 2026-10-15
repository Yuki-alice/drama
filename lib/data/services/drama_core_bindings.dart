// C ABI 绑定：Rust 核心仅两个符号。
//
// 当前为**手写**：本机缺少 libclang，ffigen 暂无法运行（见仓库根 ../../../ffigen.yaml 说明）。
// 采用 `@Native` 形式以适配 Dart 原生资源（native assets）：资源名与
// `hook/build.dart` 中 RustBuilder 的 `assetName`（`data/services/drama_core_bindings.dart`）
// 必须保持一致，默认 assetId 即本库 URI `package:drama_app/data/services/drama_core_bindings.dart`。
//
// 待本机安装 LLVM/libclang 后，改由 ffigen 生成并回写。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `char* drama_request(const char* utf8_json)`。
@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'drama_request')
external Pointer<Utf8> dramaRequest(Pointer<Utf8> utf8Json);

/// `void drama_free(char* ptr)`。
@Native<Void Function(Pointer<Utf8>)>(symbol: 'drama_free')
external void dramaFree(Pointer<Utf8> ptr);
