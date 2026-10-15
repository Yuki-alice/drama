import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../router/routes.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/glass_kit.dart';
import '../view_models/profile_view_model.dart';

/// 我的（PRD F-05）：账号占位卡 + 功能入口卡 + 免责声明占位。
///
/// 主导航分支页，只返回 body 内容。
class ProfileView extends ConsumerWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final stats = ref.watch(profileStatsProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.xxl,
      ),
      children: <Widget>[
        // 账号占位：未登录，头像 + 昵称 + 一行统计。
        GlassSurfaceCard(
          child: Row(
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.posterFallback,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person, size: 30, color: colors.textTertiary),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '未登录',
                      style: AppText.headline.copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '追剧 ${stats.favorites} · 历史 ${stats.history} · '
                      '下载 ${stats.downloads}',
                      style: AppText.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        // 功能入口：纪律四——卡内只用普通 Material/InkWell 行，不放玻璃控件。
        GlassSurfaceCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: <Widget>[
                _ProfileActionRow(
                  icon: Icons.download_outlined,
                  label: '下载管理',
                  onTap: () => context.push(AppRoutes.downloads),
                ),
                _ProfileActionRow(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => context.push(AppRoutes.settings),
                ),
                _ProfileActionRow(
                  icon: Icons.info_outline,
                  label: '关于',
                  onTap: () => context.push(AppRoutes.about),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '本应用为第三方学习用客户端，与红果官方无关。',
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }
}

/// 卡内功能入口行：图标 + 文本 + chevron（普通 InkWell，非玻璃控件）。
class _ProfileActionRow extends StatelessWidget {
  const _ProfileActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
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
