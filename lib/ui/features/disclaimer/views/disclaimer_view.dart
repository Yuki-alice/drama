import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/glass_kit.dart';
import '../view_models/disclaimer_view_model.dart';

/// 首次启动的免责声明确认页（三处免责落地之一，措辞待 Q13 定稿）。
///
/// 这是首启引导页，因此**不提供返回按钮**：路由在未确认时以 `/disclaimer`
/// 作为 `initialLocation`，确认后 `go` 到首页（见 `AppRoutes.home`）。
class DisclaimerView extends ConsumerWidget {
  const DisclaimerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    return AppGlassScaffold(
      title: '免责声明',
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.lg,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              children: <Widget>[
                Text(
                  '欢迎使用红果短剧',
                  style: AppText.headline.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '在开始使用前，请先阅读并同意以下声明。点击下方按钮，即表示你已'
                  '理解并接受全部内容。',
                  style: AppText.body.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.lg),
                const _BulletPoint(
                  '本应用是第三方非官方客户端，与「红果短剧」官方及其关联方'
                  '无任何隶属或合作关系。',
                ),
                const _BulletPoint(
                  '应用中所有剧目、视频、图片与文字内容的著作权及相关权利'
                  '均归原作者与原平台所有。',
                ),
                const _BulletPoint(
                  '本应用仅供个人学习、研究与技术交流使用，严禁用于任何'
                  '商业用途或二次分发。',
                ),
                const _BulletPoint(
                  '应用内数据来源于公开渠道，我们不对内容的准确性、完整性'
                  '与时效性作出任何保证。',
                ),
                const _BulletPoint(
                  '若权利人认为某个内容侵犯了其合法权益，请通过「关于」页的'
                  '联系方式告知，我们将及时核实并删除。',
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '（本声明措辞为占位版本，最终文本待 Q13 定稿）',
                  style: AppText.caption.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                AppSpacing.xl,
              ),
              child: Center(
                child: GlassActionButton(
                  label: '我已阅读并同意',
                  icon: Icons.check,
                  width: 220,
                  onTap: () async {
                    await ref
                        .read(disclaimerAcknowledgedProvider.notifier)
                        .acknowledge();
                    if (!context.mounted) return;
                    context.go(AppRoutes.home);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表式要点。
class _BulletPoint extends StatelessWidget {
  const _BulletPoint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: colors.textPrimary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppText.body.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
