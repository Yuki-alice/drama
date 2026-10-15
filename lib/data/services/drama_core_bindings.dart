// C ABI 绑定：Rust 核心仅两个符号。
//
// **本文件为手写且必须保持手写**：项目走 native assets，要求 `@Native` 外部
// 函数形式；而 ffigen 产出的是 `DynamicLibrary.lookup` 风格（类 + 构造函数
// 注入 DynamicLibrary），两者不兼容（见仓库根 ../../../ffigen.yaml 说明）。
//
// 资源名必须与 `hook/build.dart` 中 RustBuilder 的 `assetName`
// （`data/services/drama_core_bindings.dart`）一致，
// 默认 assetId 即本库 URI `package:drama_app/data/services/drama_core_bindings.dart`。
//
// 改动 C ABI 时：跑 `dart run ffigen --config ffigen.yaml` 比对生成结果确认
// 签名一致，把改动落到本文件，再 `git checkout` 丢弃生成结果。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `char* drama_request(const char* utf8_json)`。
@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'drama_request')
external Pointer<Utf8> dramaRequest(Pointer<Utf8> utf8Json);

/// `void drama_free(char* ptr)`。
@Native<Void Function(Pointer<Utf8>)>(symbol: 'drama_free')
external void dramaFree(Pointer<Utf8> ptr);
