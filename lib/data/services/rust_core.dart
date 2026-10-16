import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'drama_core_bindings.dart';

/// 逻辑流（= 信封里的 `session`）划分。
///
/// **绝不能用一个全局 session + 全局序号**：`session`/`sequence` 的语义是
/// 「同一 session 内新请求取代旧在途」。首页启动会**并发**打
/// `catalog / recommend / ranking / categories`，若共用一个 session，
/// 后发的会立刻把先发的判为「迟到」并返回 `CANCELED`，首页随机空白。
/// 因此按**逻辑流**分 session：只有同一逻辑流内的新请求才取代旧请求。
///
/// 纯函数，便于单测。
String logicalStreamFor(String op, Map<String, Object?>? params) {
  final args = params ?? const <String, Object?>{};
  String arg(String key) => (args[key] as String?)?.trim() ?? '';
  switch (op) {
    case 'catalog':
      final category = arg('category');
      return 'catalog:${category.isEmpty ? 'default' : _sessionToken(category)}';
    case 'recommend':
      return 'recommend';
    case 'ranking':
      final board = arg('board');
      return 'ranking:${board.isEmpty ? 'hot' : _sessionToken(board)}';
    case 'search':
      return 'search:${_sessionToken(arg('keyword'))}';
    case 'suggest':
      return 'suggest:${_sessionToken(arg('keyword'))}';
    case 'detail':
      return 'detail:${_sessionToken(arg('id'))}';
    default:
      return _sessionToken(op);
  }
}

/// session 只允许 `[0-9a-zA-Z-_:.]` 且 ≤128（Rust 侧会校验，非法即 `BAD_REQUEST`）。
///
/// 关键词 / 剧集 id 可能是中文：非法字符统一替换为 `.`（**不是 `_`**——规范字符集不含 `_`，
/// 虽然当前 Rust 实现额外容忍它，此处从严），替换后可能「撞名」，
/// 故追加 32 位哈希消歧。
String _sessionToken(String raw) {
  if (raw.isEmpty) return 'none';
  final sanitized = raw.replaceAll(RegExp(r'[^0-9a-zA-Z\-_.]'), '.');
  final trimmed = sanitized.length <= 96
      ? sanitized
      : sanitized.substring(0, 96);
  if (trimmed == raw) return trimmed;
  return '$trimmed-${_hash32(raw)}';
}

/// 32 位 FNV-1a，仅用于 session 消歧（非安全用途）。
String _hash32(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16);
}

/// 常驻 worker 池规模。
///
/// 必须 ≥2：一个 isolate 阻塞在网络上时，另一个 isolate 仍能并发处理 `cancelRead`，
/// 取消协议才在结构上可用（单 isolate 串行消费下 `cancelRead` 排不上队）。
const int kRustWorkerCount = 3;

/// Rust 核心返回的错误信封：`{code, msg, retry}`。
class RustCoreException implements Exception {
  const RustCoreException(this.code, this.msg, this.retry);

  final String code;
  final String msg;
  final bool retry;

  /// 是否因「同逻辑流内被更新的请求取代」而取消。
  ///
  /// 调用方应**静默**处理（例如忽略迟到结果），**不得**当作面向用户的错误上抛。
  bool get isSuperseded => code == 'CANCELED';

  /// 从 `{ok:false, error:{code,msg,retry}}` 构造。
  factory RustCoreException.fromEnvelope(Map<String, Object?> envelope) {
    final error = envelope['error'];
    if (error is Map) {
      return RustCoreException(
        error['code'] as String? ?? 'UNKNOWN',
        error['msg'] as String? ?? '',
        error['retry'] as bool? ?? false,
      );
    }
    return const RustCoreException(
      'UNKNOWN',
      'malformed error envelope',
      false,
    );
  }

  @override
  String toString() => 'RustCoreException($code): $msg';
}

/// Rust 核心的 Dart 侧封装：**常驻 worker isolate 池**。
///
/// 取消协议要求「一个请求阻塞在网络上时，另一个 worker 仍能处理 `cancelRead`」，
/// 因此这里是 [kRustWorkerCount] 个常驻 worker isolate 的池：请求按轮转择一投递，
/// 响应经统一 [ReceivePort] 按 `id` 回填。端口复用、常驻，绝不每次 `Isolate.run` 新建。
///
/// **取消是协作式**：`call` 按**逻辑流**取 `session`（见 [logicalStreamFor]）并维护该流内
/// 单调递增的 `sequence`，读类 op 因此被 Rust 侧仲裁（同流内旧 `sequence` 的迟到响应
/// 被丢弃为 `CANCELED`）。超时后补发 `cancelRead`。取消**不保证立即中断对端 socket**；
/// 被取消/超时的在途请求最坏情况下会占住一个 worker isolate 直到其内层超时（≤60s）。
class RustCore {
  RustCore._();

  /// 每个逻辑流各自独立的序号计数。
  final Map<String, int> _sequences = <String, int>{};

  ReceivePort? _inbox;
  List<SendPort> _workers = const <SendPort>[];
  final Map<int, Completer<String>> _pending = <int, Completer<String>>{};
  int _nextWorker = 0;
  int _messageId = 0;

  /// 启动常驻 worker 池；返回 `Future<RustCore>`（签名对既有调用方向后兼容）。
  static Future<RustCore> spawn() async {
    final core = RustCore._();
    final inbox = ReceivePort();
    core._inbox = inbox;

    final ready = Completer<void>();
    final workers = <SendPort>[];
    inbox.listen((message) {
      if (message is SendPort) {
        workers.add(message);
        if (workers.length == kRustWorkerCount && !ready.isCompleted) {
          ready.complete();
        }
        return;
      }
      if (message is Map) {
        final id = message['id'] as int;
        // 已完成/已超时的请求 → completer 已不在表内 → 静默丢弃，绝不二次 complete。
        core._pending.remove(id)?.complete(message['reply'] as String);
      }
    });

    for (var i = 0; i < kRustWorkerCount; i++) {
      await Isolate.spawn(
        _rustCoreMain,
        inbox.sendPort,
        debugName: 'drama_rust_core_$i',
      );
    }
    await ready.future;
    core._workers = workers;
    return core;
  }

  /// 轮转择一空闲 worker（并发投递负载均衡）。
  SendPort? _pickWorker() {
    final workers = _workers;
    if (workers.isEmpty) return null;
    final port = workers[_nextWorker % workers.length];
    _nextWorker = (_nextWorker + 1) % workers.length;
    return port;
  }

  /// 发送一次请求，返回解析后的响应信封。
  ///
  /// 自动带上 [session] 与单调递增 `sequence`（读类 op 因此参与 Rust 侧仲裁）。
  /// `timeout` 缺省时按 op 取外层预算（[outerTimeoutFor]，Dart 外层 > Rust 内层）。
  /// 超时后立即以 [RustCoreException] `TIMEOUT` 失败，并**补发 `cancelRead`**（fire-and-forget）。
  Future<Map<String, Object?>> call(
    String op, {
    String? source,
    Map<String, Object?>? params,
    Duration? timeout,
  }) async {
    final port = _pickWorker();
    if (port == null) {
      throw StateError('RustCore 已释放或尚未就绪');
    }

    // 逻辑流 + 该流内单调递增序号：只有同流内的新请求才取代旧在途。
    final stream = logicalStreamFor(op, params);
    final sequence = _sequences.update(
      stream,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    final id = ++_messageId;
    final payload = jsonEncode(<String, Object?>{
      'v': 1,
      'op': op,
      'source': ?source,
      'session': stream,
      'sequence': sequence,
      'params': params ?? const <String, Object?>{},
    });

    final completer = Completer<String>();
    _pending[id] = completer;
    port.send(<String, Object?>{'id': id, 'payload': payload});

    final budget = timeout ?? outerTimeoutFor(op);
    try {
      final raw = await completer.future.timeout(budget);
      return jsonDecode(raw) as Map<String, Object?>;
    } on TimeoutException {
      // 迟到到达的原请求响应将无处回填 → 静默丢弃（不二次 complete 同一个 Completer）。
      _pending.remove(id);
      // Dart 超时后**必须**补发 cancelRead，否则引擎侧在途请求泄漏。
      unawaited(_sendCancelRead(stream, sequence));
      throw RustCoreException(
        'TIMEOUT',
        'rust core op "$op" timed out after ${budget.inMilliseconds}ms',
        true,
      );
    }
  }

/// 外层超时预算（分级超时，Dart 外层 > Rust 内层，**内层先到期**）。
///
/// 纯函数，便于单测：默认 70s / `preload` 20s / `moveDownloads` 620s /
/// `catalogPages` 130s（一次串取多页，Rust 内层 120s）。
static Duration outerTimeoutFor(String op) {
  switch (op) {
    case 'preload':
      return const Duration(seconds: 20);
    case 'moveDownloads':
      return const Duration(seconds: 620);
    case 'catalogPages':
      return const Duration(seconds: 130);
    // 换档内层 15s，外层 20s（同 preload）：内层先到期，错误码才是 TIMEOUT。
    case 'playQuality':
      return const Duration(seconds: 20);
    default:
      return const Duration(seconds: 70);
  }
}

  /// 补发 `cancelRead{session, sequence}`。
  ///
  /// fire-and-forget：**不注册 completer**（其响应被静默丢弃）；调用方以 `unawaited` 明确标注。
  Future<void> _sendCancelRead(String session, int sequence) async {
    final port = _pickWorker();
    if (port == null) return;
    final id = ++_messageId;
    final payload = jsonEncode(<String, Object?>{
      'v': 1,
      'op': 'cancelRead',
      'params': <String, Object?>{'session': session, 'sequence': sequence},
    });
    port.send(<String, Object?>{'id': id, 'payload': payload});
  }

  /// W0 冒烟：`ping` → `pong`（契约见）。
  Future<String> ping() async {
    final envelope = await call('ping');
    if (envelope['ok'] == true) {
      return envelope['data']! as String;
    }
    throw RustCoreException.fromEnvelope(envelope);
  }

  /// 释放 worker 池（关闭接收端口；常驻 isolate 随 App 生命周期回收）。
  void dispose() {
    _inbox?.close();
    _inbox = null;
    _workers = const <SendPort>[];
    _pending.clear();
  }
}

/// 持有 [RustCore] 的薄包装。
///
/// 用**可空** `Provider` 表达"核心不可用"（native asset 缺失 / 初始化失败），
/// 比让 Provider 抛异常更好：上层可据此回退到 mock，而不是整站崩溃。
class RustCoreHolder {
  const RustCoreHolder(this.core);

  final RustCore core;
}

/// worker isolate 入口：接收 `{id, payload}`，调用 C ABI，回传 `{id, reply}`。
///
/// 每个 isolate 独立持有 inbox；响应统一回发到主 isolate 的共享 `outbox`（端口复用）。
void _rustCoreMain(SendPort outbox) {
  final inbox = ReceivePort();
  outbox.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! Map) return;
    final id = message['id'] as int;
    outbox.send(<String, Object?>{
      'id': id,
      'reply': _invokeRust(message['payload']! as String),
    });
  });
}

/// 在 isolate 内完成一次 FFI 往返；输入输出内存均在此处回收。
String _invokeRust(String json) {
  final input = json.toNativeUtf8();
  try {
    final output = dramaRequest(input);
    try {
      return output.toDartString();
    } finally {
      // 该指针由 Rust 侧分配，必须用 drama_free 回收（不能用 Dart malloc）。
      dramaFree(output);
    }
  } finally {
    malloc.free(input);
  }
}
