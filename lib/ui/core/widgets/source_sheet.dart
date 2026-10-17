import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/catalog_providers.dart';
import '../../../domain/models/source.dart';
import '../../features/home/view_models/home_view_model.dart';
import '../motion/app_motion.dart';
import '../tokens/app_tokens.dart';
import 'app_glass_surface.dart';

/// 「选择内容源」底部 sheet（发现页与榜单页共用）。
///
/// 只列出**有目录能力**的源（`caps.catalog`）——未声明的能力不冒充可用。
/// 能力表为空（核心不可用 / 未声明任何源）时兜底主源单行，不静默造源。
Future<void> showSourceSheet(BuildContext context, WidgetRef ref) {
  final current = ref.read(homeSourceProvider);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: AppGlassSurface(
        radius: AppRadii.sheet,
        blur: 26,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '选择内容源',
                  style: AppText.headline.copyWith(
                    color: AppColors.of(sheetContext).textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Consumer(
                  builder: (context, sheetRef, _) => sheetRef
                      .watch(availableSourcesProvider)
                      .when(
                        loading: () => const Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (error, _) => _choices(
                          context,
                          sheetRef,
                          current,
                          const <SourceInfo>[],
                        ),
                        data: (sources) {
                          final browsable = sources
                              .where((source) => source.caps.catalog)
                              .toList();
                          return _choices(
                            context,
                            sheetRef,
                            current,
                            browsable.isEmpty ? sources : browsable,
                          );
                        },
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _choices(
  BuildContext context,
  WidgetRef sheetRef,
  String current,
  List<SourceInfo> sources,
) {
  if (sources.isEmpty) {
    return const _SheetChoice(label: '红果（默认）', selected: true);
  }
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (final source in sources)
        _SheetChoice(
          // 展示名走 Rust 下发的 name（规则包 authors 起的名），
          // 规则源加「规则」角标——用户有权知道内容来自第三方规则。
          label: source.isRule ? '${source.displayName}（规则）' : source.displayName,
          selected: source.id == current,
          onTap: () {
            sheetRef.read(homeSourceProvider.notifier).select(source.id);
            Navigator.of(context).pop();
          },
        ),
    ],
  );
}

/// sheet 内的一行选项（**内容层**行，不是玻璃控件——玻璃不嵌套）。
class _SheetChoice extends StatelessWidget {
  const _SheetChoice({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .98,
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: AppSpacing.minTapTarget,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        alignment: AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: selected ? colors.selectionFill : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(
                  color: colors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 18, color: colors.textPrimary),
          ],
        ),
      ),
    );
  }
}
