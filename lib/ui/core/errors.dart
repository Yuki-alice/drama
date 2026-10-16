import 'package:flutter/material.dart';

import '../../data/services/rust_core.dart';
import 'tokens/app_tokens.dart';
import 'widgets/glass_kit.dart';

/// 把任意抛出的错误转成一句用户能读的话。
///
/// **为什么必须集中一处**：此前 6 个视图各复制了一份逐字相同的实现
/// （`error is RustCoreException ? '${error.msg}（${error.code}）' : '$error'`），
/// 错误文案格式一变就是 6 处改、且必然漏掉一两处。
///
/// 口径：
/// - [RustCoreException] 带引擎给的 `code`，**保留错误码**——用户报障时
///   报出 `TIMEOUT` 比报出「加载失败」有用得多；
/// - 其余异常直接用 `toString()`，不做「网络异常，请重试」这类猜测性包装：
///   猜错原因比不猜更糟。
String errorMessage(Object error) =>
    error is RustCoreException ? '${error.msg}（${error.code}）' : '$error';

/// 错误 / 空态的 **inline 重试行**（列表底部追加失败时用）。
///
/// P0-1 的配套：`loadMore` 失败**不能**把已加载的列表整个换成错误页，
/// 只能在列表尾部追加一条可重试的提示。这个组件就是那条提示。
class InlineRetry extends StatelessWidget {
  const InlineRetry({
    super.key,
    required this.message,
    required this.onRetry,
    this.label = '重试',
  });

  final String message;
  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.callout.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinePill(
            label: label,
            icon: Icons.refresh_rounded,
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}
