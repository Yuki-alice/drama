import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/repositories/catalog_providers.dart';
import '../../../../router/routes.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/playback/playback_settings.dart';
import '../../../core/tokens/app_tokens.dart';
import '../../../core/widgets/app_fixed_top_bar.dart';
import '../../../core/widgets/app_glass_surface.dart';
import '../../../core/widgets/app_nav_bar.dart';
import '../../../core/widgets/lockups.dart';
import '../view_models/profile_view_model.dart';

/// 我的：**整页零彩色**。
///
/// - 固定顶栏（`我的` + 设置钮）；
/// - **身份行**：头像（58 圆）+ 昵称 + 一句真实副标题；
/// - 统计三项**由数据算出**（在看 / 看完 / 约累计小时）；
/// - 设置分四组（我的内容 / 播放与下载 / 其他 / 版本号）：每组是一块浅雾
///   圆角卡，组间靠 24pt 负空间分隔，**不画外框**；
/// - 限宽 640 居中。
///
/// **不画「会员」标签**：本项目没有账号与会员体系，挂一个不存在的身份标记
/// 是虚假信息；身份行只呈现真实存在的事实（追剧数 / 历史数）。
class ProfileView extends ConsumerWidget {
  const ProfileView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final stats = ref.watch(profileStatsProvider).value ?? ProfileStats.empty;
    final playback = ref.watch(playbackSettingsProvider);
    final sourceCount = ref.watch(availableSourcesProvider).value?.length;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ListView(
          padding: EdgeInsetsDirectional.fromSTEB(
            _hpad(context),
            0,
            _hpad(context),
            tabPageBottomInset(context) + AppSpacing.xxl,
          ),
          children: <Widget>[
            const FixedTopBarInset(hasSubBar: false),
            const SizedBox(height: AppSpacing.xs),

            // ── 身份行 ─────────────────────────────────────────────
            Row(
              children: <Widget>[
                Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: Alignment(-0.4, -0.76),
                      radius: 1.2,
                      colors: <Color>[Color(0xFF5B5B63), Color(0xFF232326)],
                    ),
                  ),
                  child: Center(
                    child: Text(
                      ref.watch(greetingProvider).characters.first,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        ref.watch(greetingProvider),
                        style: AppText.barTitle.copyWith(
                          color: colors.textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '追剧 ${stats.following} 部 · 观看记录 ${stats.history} 条',
                        style: AppText.mono.copyWith(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            // ── 三项等宽统计（由数据算出） ─────────────────────────
            Row(
              children: <Widget>[
                Expanded(
                  child: _StatTile(value: '${stats.watching}', label: '在看'),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _StatTile(value: '${stats.finished}', label: '看完'),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _StatTile(
                    value: stats.hours.toStringAsFixed(1),
                    label: '小时',
                  ),
                ),
              ],
            ),

            // ── 我的内容 ───────────────────────────────────────────
            const SectionLabel(text: '我的内容', top: AppSpacing.xl),
            SettingsCard(
              rows: <Widget>[
                SettingsRow(
                  icon: Icons.download_outlined,
                  label: '下载管理',
                  value: '暂不生效',
                  onTap: () => context.push(AppRoutes.downloads),
                ),
                SettingsRow(
                  icon: Icons.history_rounded,
                  label: '观看历史',
                  value: '${stats.history} 条',
                  onTap: () => context.push(AppRoutes.downloads),
                ),
                SettingsRow(
                  icon: Icons.favorite_border,
                  label: '我的收藏',
                  value: '${stats.following} 部',
                  onTap: () => context.go(AppRoutes.library),
                ),
              ],
            ),

            // ── 播放与下载 ─────────────────────────────────────────
            const SectionLabel(text: '播放与下载', top: AppSpacing.xl),
            SettingsCard(
              rows: <Widget>[
                SettingsRow(
                  icon: Icons.play_circle_outline,
                  label: '播放设置',
                  value: playback.autoPlayNext ? '自动连播' : '不连播',
                  onTap: () => context.push(AppRoutes.settings),
                ),
                SettingsRow(
                  icon: Icons.swap_horiz_rounded,
                  label: '内容源管理',
                  value: sourceCount == null ? '—' : '$sourceCount 个源',
                  onTap: () => context.push(AppRoutes.settings),
                ),
                SettingsRow(
                  icon: Icons.wifi_rounded,
                  label: '仅 Wi-Fi 下载',
                  value: '暂不生效',
                  onTap: () => context.push(AppRoutes.settings),
                ),
              ],
            ),

            // ── 其他 ───────────────────────────────────────────────
            const SectionLabel(text: '其他', top: AppSpacing.xl),
            SettingsCard(
              rows: <Widget>[
                SettingsRow(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => context.push(AppRoutes.settings),
                ),
                SettingsRow(
                  icon: Icons.info_outline,
                  label: '关于',
                  onTap: () => context.push(AppRoutes.about),
                ),
                SettingsRow(
                  icon: Icons.gavel_outlined,
                  label: '免责声明',
                  onTap: () => context.push(AppRoutes.disclaimer),
                ),
              ],
            ),

            // ── 版本尾注（等宽，弱化到三级） ───────────────────────
            const SizedBox(height: AppSpacing.xl),
            Center(
              child: Text(
                'v1.0.0 · 内容均来自第三方源',
                style: AppText.mono.copyWith(
                  fontSize: 11.5,
                  color: colors.textTertiary,
                ),
              ),
            ),
          ],
        ),

        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FixedTopBar(
            title: '我的',
            actions: <Widget>[
              AppPlainRoundButton(
                icon: Icons.settings_outlined,
                semanticLabel: '设置',
                onPressed: () => context.push(AppRoutes.settings),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 「我的」页内容区左右留白（限宽 640 居中）。
double _hpad(BuildContext context) {
  final windowWidth = MediaQuery.sizeOf(context).width;
  final sizeClass = Breakpoints.classify(windowWidth);
  final gutter = Breakpoints.gutter(sizeClass);
  final contentWidth = windowWidth - Breakpoints.railPlaceholder(sizeClass);
  return math.max(gutter, (contentWidth - 640) / 2);
}

/// 统计格：大号等宽数字 + 标签。
class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: colors.sunken,
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(value, style: AppText.stat.copyWith(color: colors.textPrimary)),
          const SizedBox(height: 2),
          Text(
            label,
            style: AppText.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
