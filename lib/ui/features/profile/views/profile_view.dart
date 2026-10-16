import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../router/routes.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_glass_scaffold.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/glass_kit.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/profile_view_model.dart';

/// 我的。
///
/// 结构：大标题 + 玻璃设置钮 → 账号卡（玻璃材质）→ 三项等宽统计
/// （追剧 / 历史 / 下载）→ 设置列表（下载管理 / 观看历史 / 设置 / 关于 /
/// 免责声明）→ 版本尾注。
///
/// 统计数字走**等宽字族**：三项并排时数字宽度一致，读数不跳动。
class ProfileView extends ConsumerWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    // 核心不可用/加载中/出错都回落全零占位，不阻断入口页导航。
    final stats = ref.watch(profileStatsProvider).value ?? ProfileStats.empty;

    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        navBarBottomClearance(context) + AppSpacing.lg,
      ),
      children: <Widget>[
        const GlassContentTopInset(extra: AppSpacing.sm),
        PageHead(
          title: '我的',
          actions: <Widget>[
            GlassIconAction(
              icon: Icons.settings_outlined,
              semanticLabel: '设置',
              onPressed: () => context.push(AppRoutes.settings),
            ),
          ],
        ),

        // ── 账号卡（玻璃材质） ─────────────────────────────────────
        GlassSurfaceCard(
          child: Row(
            children: <Widget>[
              // 头像底走「浅雾」而不是灰阶：它是凹陷面，不是浮起面。
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: colors.sunken,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_outline,
                  size: 28,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '未登录',
                      style: AppText.headline.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '登录可同步追剧与观看进度',
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
        const SizedBox(height: AppSpacing.md),

        // ── 三项等宽统计 ──────────────────────────────────────────
        Row(
          children: <Widget>[
            Expanded(
              child: _StatTile(
                value: '${stats.favorites}',
                label: '追剧',
                onTap: () => context.go(AppRoutes.library),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _StatTile(
                value: '${stats.history}',
                label: '历史',
                onTap: () => context.push(AppRoutes.downloads),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _StatTile(
                value: '${stats.downloads}',
                label: '下载',
                onTap: () => context.push(AppRoutes.downloads),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),

        // ── 设置列表（内容层行；玻璃卡里不放玻璃控件） ─────────────
        GlassSurfaceCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: <Widget>[
                _ActionRow(
                  icon: Icons.download_outlined,
                  label: '下载管理',
                  onTap: () => context.push(AppRoutes.downloads),
                ),
                _ActionRow(
                  icon: Icons.history_rounded,
                  label: '观看历史',
                  onTap: () => context.push(AppRoutes.downloads),
                ),
                _ActionRow(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => context.push(AppRoutes.settings),
                ),
                _ActionRow(
                  icon: Icons.info_outline,
                  label: '关于',
                  onTap: () => context.push(AppRoutes.about),
                ),
                _ActionRow(
                  icon: Icons.gavel_outlined,
                  label: '免责声明',
                  onTap: () => context.push(AppRoutes.disclaimer),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── 版本尾注（等宽，弱化到三级） ──────────────────────────
        Center(
          child: Text(
            '红果短剧 · 1.0.0',
            style: AppText.mono.copyWith(color: colors.textTertiary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Center(
          child: Text(
            '第三方学习用客户端，与红果官方无关',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: colors.textTertiary),
          ),
        ),
      ],
    );
  }
}

/// 统计格：大号等宽数字 + 标签。
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.xl,
      onTap: onTap,
      semanticLabel: '$label $value',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.contentSurface,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: colors.divider),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              value,
              style: AppText.stat.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: AppText.caption.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡内功能入口行：图标 + 文本 + chevron（普通 InkWell，非玻璃控件）。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
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
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
