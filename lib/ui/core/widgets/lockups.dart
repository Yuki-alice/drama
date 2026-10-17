import 'package:flutter/material.dart';

import '../../../domain/models/drama.dart';
import '../layout/breakpoints.dart';
import '../motion/app_motion.dart';
import '../tokens/app_tokens.dart';
import 'drama_cover.dart';

// 内容层版式词汇表（**无彩色界面**）。
//
// 全部落在内容层（不透明），因此不使用任何玻璃控件。
// 四条纪律（设计宪法第二节）：
//   1. 封面不裁切 —— 一律按 3:4 原始比例渲染，禁止 `fill` 后裁切；
//   2. 内容即界面 —— 标题与集数叠在封面下缘 scrim 上，卡片**无独立文本区**；
//   3. 分层靠排版与负空间 —— 卡片默认无描边、无阴影、无容器色差；
//   4. 续播做进卡片 —— 看过的卡右上角白胶囊 + 下缘发丝进度线。

/// 发现页 / 搜索结果的海报卡（原型 `card()`）。
///
/// 全屏都是这种竖卡：**没有横滑区、没有 banner、没有分区头条**。
/// 卡片只有封面一层，标题与集数叠在下缘 scrim 上——这样密度才能上去。
class DramaPosterCard extends StatelessWidget {
  const DramaPosterCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.watchedEpisode = 0,
    this.progress = 0,
    this.heroEnabled = true,
  });

  final Drama drama;
  final VoidCallback onTap;

  /// 已看到第几集；`0` = 未看过（显示题材角标而不是续播胶囊）。
  final int watchedEpisode;

  /// 0–1 进度（仅在看过的卡上画下缘发丝线）。
  final double progress;

  /// 是否参与封面 Hero 转场（同一路由内标签必须唯一）。
  final bool heroEnabled;

  bool get _seen => watchedEpisode > 0;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final cover = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DramaCover(
          seed: drama.coverSeed,
          cover: drama.cover,
          title: drama.title,
          radius: AppRadii.lg,
          fill: true,
        ),
        // 下缘 scrim：保证叠在封面上的标题可读（58% 高）。
        Positioned.fill(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.58,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Color(0xD1000000),
                      Color(0x66000000),
                      Color(0x00000000),
                    ],
                    stops: <double>[0.0, 0.44, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_seen)
          PositionedDirectional(
            top: 8,
            end: 8,
            child: _ResumePill(episode: watchedEpisode),
          )
        else if (drama.tags.isNotEmpty)
          PositionedDirectional(
            top: 8,
            start: 8,
            child: _TagBadge(text: drama.tags.first),
          ),
        PositionedDirectional(
          start: 9,
          end: 9,
          bottom: 9,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  letterSpacing: -0.1,
                  color: Color(0xFFFFFFFF),
                  shadows: <Shadow>[
                    Shadow(color: Color(0x73000000), blurRadius: 6),
                  ],
                ),
              ),
              if (drama.episodeCount > 0) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  '全 ${drama.episodeCount} 集',
                  style: AppText.mono.copyWith(
                    fontSize: 10,
                    color: colors.onMediaSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_seen)
          PositionedDirectional(
            start: 9,
            end: 9,
            bottom: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 2,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    const ColoredBox(color: Color(0x4DFFFFFF)),
                    FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: progress.clamp(0.0, 1.0),
                      child: const ColoredBox(color: Color(0xFFFFFFFF)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    final rounded = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: cover,
    );

    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.lg,
      onTap: onTap,
      semanticLabel: <String>[
        drama.title,
        if (drama.episodeCount > 0) '全 ${drama.episodeCount} 集',
        if (_seen) '看到第 $watchedEpisode 集',
      ].join('，'),
      semanticHint: '双击查看详情',
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: heroEnabled
            ? CoverHero(source: drama.source, id: drama.id, child: rounded)
            : rounded,
      ),
    );
  }
}

/// 看过的卡右上角的白色续播胶囊（「继续看 N」）。
class _ResumePill extends StatelessWidget {
  const _ResumePill({required this.episode});

  final int episode;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xEBFFFFFF),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '继续看 $episode',
      style: AppText.mono.copyWith(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF0F0F0F),
      ),
    ),
  );
}

/// 未看过的卡左上角的题材角标（半透明黑底白字）。
class _TagBadge extends StatelessWidget {
  const _TagBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0x6B000000),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: AppText.caption.copyWith(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: const Color(0xFFFFFFFF),
      ),
    ),
  );
}

/// 榜单行：**数字即视觉**（大号等宽序号 + 发丝分隔）。
///
/// 前三名墨黑、其余银灰——名次差靠字色而不是奖牌图标表达。
/// 缩略图 50×68，比行内文字还小：排行榜里用户读的是名次和剧名。
class RankRow extends StatelessWidget {
  const RankRow({
    super.key,
    required this.drama,
    required this.rank,
    required this.onTap,
    this.hotLabel,
  });

  final Drama drama;
  final int rank;
  final VoidCallback onTap;

  /// 热度文案（等宽）；null 时不显示。
  final String? hotLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final top = rank <= 3;
    final meta = <String>[
      if (drama.episodeCount > 0) '全 ${drama.episodeCount} 集',
      if (drama.tags.isNotEmpty) drama.tags.first,
    ].join(' · ');

    return PressableScale(
      scale: .98,
      onTap: onTap,
      semanticLabel: '第 $rank 名，${drama.title}，$meta',
      semanticHint: '双击查看详情',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.divider, width: .5)),
        ),
        child: Row(
          children: <Widget>[
            // 名次列固定 36pt；三位数（榜单可到 100+）用 FittedBox 等比缩下来，
            // 而不是撑宽列或裁掉高位。
            SizedBox(
              width: 36,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.center,
                child: Text(
                  '$rank',
                  style: AppText.numeral.copyWith(
                    color: top ? colors.textPrimary : colors.textTertiary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              height: 68,
              width: 50,
              child: CoverHero(
                source: drama.source,
                id: drama.id,
                child: DramaCover(
                  seed: drama.coverSeed,
                  cover: drama.cover,
                  title: drama.title,
                  radius: AppRadii.thumbnail,
                  fill: true,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontSize: 14,
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (meta.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.mono.copyWith(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hotLabel != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: AppSpacing.md),
                child: Text(
                  hotLabel!,
                  style: AppText.mono.copyWith(
                    fontSize: 11,
                    color: colors.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 追剧行：缩略封面 + 标题 + 状态 + **2px 墨色进度线** + 右侧胶囊。
///
/// 进度线贴着剧名下方，是全页唯一的「重量」。
/// 右侧胶囊按状态换字：在追=「继续看」，看完=「重看」。
class FollowRow extends StatelessWidget {
  const FollowRow({
    super.key,
    required this.title,
    required this.onTap,
    required this.onPlay,
    this.id = '',
    this.source = '',
    this.cover = '',
    this.seed = '',
    this.statusLine,
    this.progress = 0,
    this.actionLabel,
  });

  final String title;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  /// 剧目 id / 源（供封面 Hero 与详情页对齐；为空则不挂 Hero）。
  final String id;
  final String source;

  final String cover;
  final String seed;

  /// 状态文案（「看到 34 集 · 更新至 38 集」）。
  final String? statusLine;

  /// 0–1 进度。
  final double progress;

  /// 右侧胶囊文案；默认「继续看」。
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final coverWidget = DramaCover(
      seed: seed.isEmpty ? title : seed,
      cover: cover,
      title: title,
      radius: AppRadii.thumbnail,
      fill: true,
    );

    return Semantics(
      button: true,
      label: <String>[title, ?statusLine].join('，'),
      hint: '双击查看详情',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.divider, width: .5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // 空 id 不包 Hero：标签空串会让同页多行共享同一 tag，断言失败。
            SizedBox(
              height: 76,
              width: 56,
              child: id.isEmpty
                  ? coverWidget
                  : CoverHero(source: source, id: id, child: coverWidget),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: PressableScale(
                scale: .98,
                onTap: onTap,
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        fontSize: 14.5,
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (statusLine != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        statusLine!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono.copyWith(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 9),
                    // 进度线：2px 墨色，贴剧名下方。
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 2,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            ColoredBox(color: colors.divider),
                            FractionallySizedBox(
                              alignment: AlignmentDirectional.centerStart,
                              widthFactor: progress.clamp(0.0, 1.0),
                              child: ColoredBox(color: colors.textPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            InkPillSmall(label: actionLabel ?? '继续看', onTap: onPlay),
          ],
        ),
      ),
    );
  }
}

/// 列表行内的小墨色胶囊（原型 `.pill.sm`：高 36 / 13px / 左右 15）。
class InkPillSmall extends StatelessWidget {
  const InkPillSmall({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: colors.textPrimary,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: colors.onInk.withValues(alpha: .12),
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Center(
                child: Text(
                  label,
                  style: AppText.callout.copyWith(
                    fontSize: 13,
                    color: colors.onInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空态：图标 + 一句说明 + 一个出口，**不留白屏**。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: 64,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.sunken,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 24, color: colors.textTertiary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              fontSize: 15,
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(
                fontSize: 12.5,
                height: 1.6,
                color: colors.textSecondary,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xl),
            _InkPill(label: actionLabel!, onTap: onAction!),
          ],
        ],
      ),
    );
  }
}

/// 空态的出口按钮（原型 `.pill`：高 44 / 15px / 左右 20）。
class _InkPill extends StatelessWidget {
  const _InkPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: colors.textPrimary,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: colors.onInk.withValues(alpha: .12),
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Center(
                child: Text(
                  label,
                  style: AppText.body.copyWith(
                    color: colors.onInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置类分组卡（原型的 `.listcard`：浅雾底、圆角 14、行间发丝线）。
///
/// 组是一块**浅雾圆角卡**，组间靠 24pt 负空间分隔，**不画外框**。
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: ColoredBox(
        color: colors.contentSurface,
        child: Column(
          children: <Widget>[
            for (var index = 0; index < rows.length; index++) ...<Widget>[
              rows[index],
              if (index < rows.length - 1)
                Container(height: .5, color: colors.divider),
            ],
          ],
        ),
      ),
    );
  }
}

/// 设置类行：图标方格（30×30 圆角 9）+ 文字 + 右侧值（等宽）+ 箭头。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;

  /// 右侧值（等宽，纵向对齐）。
  final String? value;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Semantics(
      button: onTap != null,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppRadii.lg),
            child: Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.surfaceElevated,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 16, color: colors.textPrimary),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: AppText.body.copyWith(
                      fontSize: 14.5,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (value != null)
                  Text(
                    value!,
                    style: AppText.mono.copyWith(
                      fontSize: 12.5,
                      color: colors.textTertiary,
                    ),
                  ),
                const SizedBox(width: AppSpacing.sm),
                Icon(Icons.chevron_right, size: 16, color: colors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报网格的**连续密度**参数（列数由可用宽推出，见 `Breakpoints`）。
abstract final class FeedGrid {
  static const double gap = Breakpoints.kGridGap;

  /// 卡片只有封面一层，所以宽高比恒为 3:4（标题叠在封面上，不占额外高度）。
  static const double cardAspectRatio = 3 / 4;

  /// 由网格**内层**宽度（已扣掉左右 gutter）算出列数。
  static int columns(double innerWidth) =>
      Breakpoints.feedColumns(innerWidth.clamp(0, Breakpoints.kGridMaxWidth));

  static SliverGridDelegate delegate(double innerWidth) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns(innerWidth),
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        childAspectRatio: cardAspectRatio,
      );
}
