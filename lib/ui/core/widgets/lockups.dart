import 'package:flutter/material.dart';

import '../../../domain/models/drama.dart';
import '../motion/app_motion.dart';
import '../tokens/app_tokens.dart';
import 'drama_cover.dart';
import 'glass_kit.dart';

// 内容层版式词汇表。
//
// 问题背景：此前全站只有一种 `DramaPosterCard` 反复出现，于是整页读起来像
// 一张表格——用户无法从**形状**上分辨「这是重点推荐」「这是接着看」
// 「这是榜单」。这里把词汇表补齐：hero / 竖版海报 / 横版继续观看 /
// 榜单行 / 缩略行，每种形状承担一种明确的信息角色。
//
// 全部落在**内容层**（不透明），因此不使用任何玻璃控件。

/// 区块标题：标题 + 可选副标题 + 可选右侧动作。
///
/// 标题用 [AppText.title]（22）而不是 display（32）——层级差靠字号阶梯
/// 表达，不靠加分隔线。
class SectionHead extends StatelessWidget {
  const SectionHead({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(0, AppSpacing.lg, 0, AppSpacing.md),
  });

  /// 自带页面左右边距的变体。
  ///
  /// 供**没有外层 padding** 的 `ListView` 使用（设置 / 关于 / 下载这类
  /// 逐项自己控边距的页面）。滚在 `CustomScrollView` 里、外层已用
  /// `AppSpacing.pageH` 包住的场景请用默认构造，否则会双重缩进。
  const SectionHead.paged({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
  }) : padding = const EdgeInsets.fromLTRB(
         AppSpacing.gutter,
         AppSpacing.lg,
         AppSpacing.gutter,
         AppSpacing.md,
       );

  final String title;
  final String? subtitle;

  /// 右侧动作文案（「查看全部」）。
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: AppText.title.copyWith(color: colors.textPrimary),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: AppText.callout.copyWith(color: colors.textTertiary),
                  ),
              ],
            ),
          ),
          if (action != null)
            // 44pt 可点区：文案小，但命中区不缩水。
            PressableScale(
              scale: .94,
              onTap: onAction,
              semanticLabel: action,
              child: SizedBox(
                height: AppSpacing.minTapTarget,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      action!,
                      style: AppText.callout.copyWith(
                        // 行内动作文字 = 链接形态：绿色小字用 accentDeep。
                        color: colors.accentDeep,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 页级大标题 + 右侧动作区（各主导航页的统一抬头）。
///
/// iOS 26 的两段式：滚动内容里是**大标题**，滚上去后收窄进顶栏。
/// 这里只负责内容里的那一段（顶栏由外壳提供）。
class PageHead extends StatelessWidget {
  const PageHead({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.trailingText,
  });

  final String title;

  /// 右侧玻璃圆钮（搜索 / 排序 / 设置 / 管理）。
  final List<Widget> actions;

  /// 右侧文字补充（「共 12 部」）。与 [actions] 可同时存在。
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.sm,
        bottom: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: AppText.display.copyWith(color: colors.textPrimary),
            ),
          ),
          if (trailingText != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Text(
                trailingText!,
                style: AppText.mono.copyWith(color: colors.textSecondary),
              ),
            ),
          for (final action in actions) ...<Widget>[
            const SizedBox(width: AppSpacing.sm),
            action,
          ],
        ],
      ),
    );
  }
}

/// 全宽 Hero：内容出血，标题与元信息坐在画面上。
///
/// 这是首页的**唯一**重点位。一个页面只放一个 hero——
/// 放两个就等于没有重点。
class HeroLockup extends StatelessWidget {
  const HeroLockup({
    super.key,
    required this.drama,
    required this.onTap,
    this.height = 380,
    this.aspectRatio = 2.7,
  });

  final Drama drama;
  final VoidCallback onTap;

  /// 固定高度（紧凑宽度用）。
  final double height;

  /// 宽屏下的宽高比（横版裁切，聚焦人物）。
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .985,
      borderRadius: AppRadii.xxl,
      onTap: onTap,
      semanticLabel: '${drama.title}，${drama.categoryName}',
      semanticHint: '双击查看详情',
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DramaCover(
              seed: drama.coverSeed,
              cover: drama.cover,
              title: drama.title,
              radius: AppRadii.xxl,
              showTitleOverlay: false,
              fill: true,
            ),
            // 底部压深保证标题可读；这也是 hero 与下方内容的接缝。
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.xxl),
                gradient: const LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: <Color>[
                    Color(0xE6000000),
                    Color(0x33000000),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            PositionedDirectional(
              start: AppSpacing.lg,
              end: AppSpacing.lg,
              bottom: AppSpacing.lg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 播放圆钮与剧名**内联**：一眼看到「这里能点着看」。
                  Row(
                    children: <Widget>[
                      _PlayDot(color: colors.onMedia),
                      const SizedBox(width: AppSpacing.sm),
                      _MediaBadge(text: drama.status.label),
                      const SizedBox(width: AppSpacing.xs),
                      if (drama.episodeCount > 0)
                        _MediaBadge(
                          text: '全 ${drama.episodeCount} 集',
                          mono: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.display.copyWith(color: colors.onMedia),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    <String>[
                      drama.categoryName,
                      if (drama.tags.isNotEmpty) drama.tags.first,
                      drama.status.label,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.callout.copyWith(
                      color: colors.onMediaSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayDot extends StatelessWidget {
  const _PlayDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    height: 30,
    width: 30,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .92),
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.play_arrow_rounded, size: 20, color: Colors.black),
  );
}

/// 画面之上的小徽章（状态 / 热度 / 集数）。
class _MediaBadge extends StatelessWidget {
  const _MediaBadge({required this.text, this.mono = false});

  final String text;

  /// 数字类内容走等宽，纵向对齐。
  final bool mono;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0x59000000),
      borderRadius: BorderRadius.circular(AppRadii.xs),
      border: Border.all(color: const Color(0x2EFFFFFF)),
    ),
    child: Text(
      text,
      style: (mono ? AppText.mono : AppText.caption).copyWith(
        color: Colors.white,
        fontSize: 11.5,
      ),
    ),
  );
}

/// 竖版海报卡（货架与网格主力）。
///
/// 角标固定显示集数（等宽），标题一行 + 元信息一行。
class PosterLockup extends StatelessWidget {
  const PosterLockup({
    super.key,
    required this.drama,
    required this.onTap,
    this.width = 148,
    this.showMeta = true,
    this.fill = false,
  });

  final Drama drama;
  final VoidCallback onTap;
  final double width;

  /// 是否显示标题下方的元信息行（网格里空间紧时可关）。
  final bool showMeta;

  /// `true` = 填满父级约束（网格格子已定形状），不强制 [width]。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final meta = drama.episodeCount > 0
        ? '${drama.status.label} · 共 ${drama.episodeCount} 集'
        : drama.status.label;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // fill 时封面吃掉剩余高度；否则按 3:4 自撑。
        if (fill)
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _cover()),
                if (drama.episodeCount > 0)
                  PositionedDirectional(
                    end: AppSpacing.xs,
                    bottom: AppSpacing.xs,
                    child: _CountBadge(count: drama.episodeCount),
                  ),
              ],
            ),
          )
        else
          Stack(
            children: <Widget>[
              AspectRatio(aspectRatio: 3 / 4, child: _cover()),
              if (drama.episodeCount > 0)
                PositionedDirectional(
                  end: AppSpacing.xs,
                  bottom: AppSpacing.xs,
                  child: _CountBadge(count: drama.episodeCount),
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          drama.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.headline.copyWith(color: colors.textPrimary),
        ),
        if (showMeta) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 元信息用 textSecondary（4.72:1）而非 textTertiary（2.29:1）：
            // 集数/状态是用户真的会读的信息。
            style: AppText.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );

    final body = fill
        ? content
        : SizedBox(width: width, child: content);

    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.lg,
      onTap: onTap,
      semanticLabel: '${drama.title}，$meta',
      semanticHint: '双击查看详情',
      child: body,
    );
  }

  Widget _cover() => DramaCover(
    seed: drama.coverSeed,
    cover: drama.cover,
    title: drama.title,
    radius: AppRadii.lg,
    showTitleOverlay: false,
    fill: true,
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(AppRadii.xs),
    ),
    child: Text(
      '$count 集',
      style: AppText.mono.copyWith(
        color: Colors.white,
        fontSize: 11,
        height: 1.5,
      ),
    ),
  );
}

/// 横版「继续观看」卡：16:9 画面 + **常驻**发丝进度线。
///
/// 进度线常驻，不用点开才知道追到哪——短剧的核心痛点是「上次看到哪了」。
class ContinueLockup extends StatelessWidget {
  const ContinueLockup({
    super.key,
    required this.drama,
    required this.onTap,
    this.width = 220,
    this.progress,
    this.progressLabel,
  });

  final Drama drama;
  final VoidCallback onTap;
  final double width;

  /// 0–1 的整体进度；为 null 时不画进度线。
  final double? progress;

  /// 进度文案（「看到第 12 集」）。
  final String? progressLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return PressableScale(
      scale: .96,
      borderRadius: AppRadii.lg,
      onTap: onTap,
      semanticLabel: <String>[
        drama.title,
        ?progressLabel,
      ].join('，'),
      semanticHint: '双击继续观看',
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Stack(
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: DramaCover(
                    seed: drama.coverSeed,
                    cover: drama.cover,
                    title: drama.title,
                    radius: AppRadii.lg,
                    showTitleOverlay: false,
                    fill: true,
                  ),
                ),
                Positioned.fill(
                  child: Center(
                    child: Container(
                      height: 36,
                      width: 36,
                      decoration: BoxDecoration(
                        color: const Color(0x80000000),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0x8CFFFFFF)),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                if (progress != null)
                  PositionedDirectional(
                    start: 0,
                    end: 0,
                    bottom: 0,
                    child: HairlineProgress(
                      fraction: progress!,
                      color: colors.onMedia,
                      track: colors.hairlineTrack,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              drama.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.headline.copyWith(color: colors.textPrimary),
            ),
            if (progressLabel != null)
              Text(
                progressLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono.copyWith(color: colors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

/// 榜单行：**数字即视觉**（大号等宽序号 + 发丝分隔）。
///
/// 前三名用墨黑，其余用银灰——名次差靠字色而不是奖牌图标表达。
class RankRow extends StatelessWidget {
  const RankRow({
    super.key,
    required this.drama,
    required this.rank,
    required this.onTap,
    this.trailing,
  });

  final Drama drama;
  final int rank;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final top = rank <= 3;
    final meta = <String>[
      drama.categoryName,
      if (drama.episodeCount > 0) '${drama.episodeCount} 集',
      drama.status.label,
    ].join(' · ');

    return PressableScale(
      scale: .98,
      borderRadius: AppRadii.md,
      onTap: onTap,
      semanticLabel: '第 $rank 名，${drama.title}，$meta',
      semanticHint: '双击查看详情',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: <Widget>[
            // 名次列固定 42pt：1–2 位保持 30pt 的「数字即视觉」重量；
            // 3 位（榜单可以到 100+）用 `FittedBox` 等比缩下来，
            // 而不是撑宽列或裁掉高位——实测 30pt 等宽数字约 29pt/字符，
            // 三位就是 87pt，硬排会挤掉右侧标题。
            SizedBox(
              width: 42,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.center,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: AppText.numeral.copyWith(
                    color: top ? colors.textPrimary : colors.textTertiary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              height: 64,
              width: 48,
              child: CoverHero(
                source: drama.source,
                id: drama.id,
                child: DramaCover(
                  seed: drama.coverSeed,
                  cover: drama.cover,
                  title: drama.title,
                  radius: AppRadii.thumbnail,
                  showTitleOverlay: false,
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
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono.copyWith(
                      color: colors.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 追剧行：缩略封面 + 标题 + 集内进度 + 发丝进度线 + 墨色「继续看」。
///
/// 与榜单行的区别是它承载**进度**，所以行更高、进度线常驻。
class LibraryRow extends StatelessWidget {
  const LibraryRow({
    super.key,
    required this.title,
    required this.onTap,
    required this.onPlay,
    this.id = '',
    this.source = '',
    this.cover = '',
    this.seed = '',
    this.watchedEpisode = 0,
    this.totalEpisode = 0,
    this.progress = 0,
    this.statusLine,
    this.updatedLabel,
  });

  final String title;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  /// 剧目 id / 源（供封面 Hero 与详情页对齐；为空则不挂 Hero）。
  final String id;
  final String source;

  final String cover;
  final String seed;

  /// 已看到第几集（0 = 未开始）。
  final int watchedEpisode;

  /// 总集数（0 = 未知，不画进度线）。
  final int totalEpisode;

  /// 0–1 进度。
  final double progress;

  /// 覆盖默认的「看到第 N 集 / 共 M 集」文案。
  final String? statusLine;

  /// 「3 小时前更新」这类更新徽章。
  final String? updatedLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final line = statusLine ??
        (totalEpisode > 0
            ? '看到第 $watchedEpisode 集 / 共 $totalEpisode 集'
            : '看到第 $watchedEpisode 集');

    return Semantics(
      button: true,
      label: '$title，$line',
      hint: '双击查看详情',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            PressableScale(
              scale: .94,
              borderRadius: AppRadii.thumbnail,
              onTap: onTap,
              child: SizedBox(
                height: 92,
                width: 69,
                // 追剧行也参与封面 Hero。**空 id 不包**：标签空串会让
                // 同一页多行共享同一 tag，飞行扫描直接断言失败。
                child: id.isEmpty
                    ? DramaCover(
                        seed: seed.isEmpty ? title : seed,
                        cover: cover,
                        title: title,
                        radius: AppRadii.thumbnail,
                        showTitleOverlay: false,
                        fill: true,
                      )
                    : CoverHero(
                        source: source.isEmpty ? 'hongguo' : source,
                        id: id,
                        child: DramaCover(
                          seed: seed.isEmpty ? title : seed,
                          cover: cover,
                          title: title,
                          radius: AppRadii.thumbnail,
                          showTitleOverlay: false,
                          fill: true,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  PressableScale(
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
                          style: AppText.headline.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.mono.copyWith(
                            color: colors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 总集数未知时不画进度线：分母不明，画出来是假精度。
                  if (totalEpisode > 0) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    HairlineProgress(fraction: progress),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      InkPill(
                        label: watchedEpisode > 0 ? '继续看' : '开始看',
                        icon: Icons.play_arrow_rounded,
                        dense: true,
                        height: 32,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        onTap: onPlay,
                        semanticHint: '从第 $watchedEpisode 集继续',
                      ),
                      if (updatedLabel != null) ...<Widget>[
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Text(
                            updatedLabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              // 「还有未看的」= 待处理状态 → 绿。
                              color: colors.accentDeep,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向货架：标题 + 横滚内容。
///
/// 高度必须由调用方给（横滚列表在纵向上是无界的）。
class Shelf extends StatelessWidget {
  const Shelf({
    super.key,
    required this.title,
    required this.height,
    required this.children,
    this.subtitle,
    this.action,
    this.onAction,
    this.leadingPadding = AppSpacing.gutter,
    this.trailingPadding = AppSpacing.gutter,
  });

  final String title;
  final String? subtitle;
  final double height;
  final List<Widget> children;
  final String? action;
  final VoidCallback? onAction;
  final double leadingPadding;
  final double trailingPadding;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: leadingPadding,
          end: trailingPadding,
        ),
        child: SectionHead(
          title: title,
          subtitle: subtitle,
          action: action,
          onAction: onAction,
        ),
      ),
      SizedBox(
        height: height,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsetsDirectional.only(
            start: leadingPadding,
            end: trailingPadding,
          ),
          children: children,
        ),
      ),
    ],
  );
}

/// 海报网格的单一参数来源。
///
/// 此前 `home_view` 内联一份、`content_widgets` 又一份，改比例必然漂移。
abstract final class PosterGrid {
  /// 单列最大宽度（列数随可用宽度自动变化：手机 2 列、平板 4 列、桌面 6 列）。
  static const double maxCrossAxisExtent = 172;

  /// 3:4 封面 + 标题 + 元信息 ≈ 0.62。
  static const double childAspectRatio = 0.62;

  static const double mainAxisSpacing = AppSpacing.lg;
  static const double crossAxisSpacing = AppSpacing.md;

  static SliverGridDelegate delegate({double maxExtent = maxCrossAxisExtent}) =>
      SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
      );
}
