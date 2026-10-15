import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/content_widgets.dart';
import '../../../core/widgets/glass_kit.dart';

/// 关于页（二级页）。
///
/// 内容全为占位文案：应用标识 + 免责声明（三处免责落地之一，措辞待 Q13 定稿
/// ——另外两处为设置页文案与首启引导页）+ 开源许可 + 联系方式。
class AboutView extends StatelessWidget {
  const AboutView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return AppGlassScaffold(
      title: '关于',
      leading: GlassIconAction(
        icon: Icons.arrow_back_ios_new,
        semanticLabel: '返回',
        onPressed: () => context.pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        children: <Widget>[
          const SizedBox(height: AppSpacing.xl),
          const _AppIdentity(),
          const SizedBox(height: AppSpacing.lg),

          // ── 免责声明 ───────────────────────────────────────────
          const SectionHeader(title: '免责声明'),
          Padding(
            padding: AppSpacing.pageH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Paragraph(
                  '本应用为第三方非官方客户端，与「红果短剧」官方及其关联方'
                  '不存在任何隶属、授权或合作关系。',
                  colors: colors,
                ),
                _Paragraph(
                  '应用内展示的剧目、视频、图片与文字内容，其著作权及相关权利'
                  '均归原作者与原平台所有。',
                  colors: colors,
                ),
                _Paragraph(
                  '本应用仅供个人学习与技术交流使用，请勿用于任何商业用途，'
                  '也请勿二次分发传播。',
                  colors: colors,
                ),
                _Paragraph(
                  '若权利人认为相关内容侵犯其合法权益，可通过下方联系方式'
                  '与我们取得联系，我们将第一时间核实并删除。',
                  colors: colors,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '（措辞待 Q13 定稿）',
                  style: AppText.caption.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),

          // ── 开源许可 ───────────────────────────────────────────
          const SectionHeader(title: '开源许可'),
          _TappableRow(
            label: '查看开源许可',
            onTap: () => _showPlaceholderDialog(context, '开源许可'),
          ),

          // ── 联系方式 ───────────────────────────────────────────
          const SectionHeader(title: '联系方式'),
          const _ValueRow(label: '联系邮箱', value: 'support@example.com'),
        ],
      ),
    );
  }
}

/// 顶部应用标识：图标占位 + 应用名 + 版本 + 免责一行。
class _AppIdentity extends StatelessWidget {
  const _AppIdentity();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Column(
      children: <Widget>[
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: colors.posterFallback,
            borderRadius: BorderRadius.circular(AppRadii.xl),
          ),
          child: Icon(
            Icons.local_fire_department,
            size: 48,
            color: colors.accent,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '红果短剧',
          style: AppText.title.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '1.0.0 (W1)',
          style: AppText.callout.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '第三方学习用客户端，与红果官方无关',
          style: AppText.caption.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }
}

/// 免责声明段落。
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text, {required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: Text(
      text,
      style: AppText.body.copyWith(color: colors.textSecondary),
    ),
  );
}

/// 可点击的普通行。
class _TappableRow extends StatelessWidget {
  const _TappableRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.lg,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(color: colors.textPrimary),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: colors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 只读信息行（标签 + 值）。
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.lg,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: AppText.body.copyWith(color: colors.textPrimary),
            ),
          ),
          Text(
            value,
            style: AppText.callout.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// W1 占位弹窗。
Future<void> _showPlaceholderDialog(BuildContext context, String title) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: const Text('该内容属于 W1 纯 UI 外壳，具体实现将在后续版本补齐。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
