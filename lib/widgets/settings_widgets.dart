import 'package:flutter/material.dart';

import 'package:duanju_app/app/app_screen.dart';

/// 设置页的分栏上下文：右侧面板内嵌时不重复绘制顶栏与返回。
class SettingsPaneScope extends InheritedWidget {
  const SettingsPaneScope({
    super.key,
    required this.embedded,
    required this.showBackButton,
    required this.onBack,
    required super.child,
  });

  final bool embedded;
  final bool showBackButton;
  final VoidCallback onBack;

  static SettingsPaneScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsPaneScope>();

  @override
  bool updateShouldNotify(SettingsPaneScope oldWidget) =>
      embedded != oldWidget.embedded ||
      showBackButton != oldWidget.showBackButton ||
      onBack != oldWidget.onBack;
}

/// 分类页骨架：独立路由时用 AppScreen，嵌在设置分栏里时用轻量顶栏。
class SettingsDetailScaffold extends StatelessWidget {
  const SettingsDetailScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.leading,
    this.maxContentWidth,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? leading;
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final scope = SettingsPaneScope.of(context);
    if (scope == null || !scope.embedded) {
      return AppScreen(
        title: title,
        leading: leading,
        actions: actions ?? const [],
        maxContentWidth: maxContentWidth,
        body: body,
      );
    }
    final paneLeading =
        leading ??
        (scope.showBackButton
            ? BackButton(onPressed: scope.onBack)
            : null);
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            elevation: 0,
            automaticallyImplyLeading: false,
            toolbarHeight: 64,
            titleSpacing: paneLeading == null
                ? 24
                : NavigationToolbar.kMiddleSpacing,
            leading: paneLeading,
            title: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            actions: actions,
          ),
          Expanded(
            child: maxContentWidth == null
                ? body
                : Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxContentWidth!),
                      child: body,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.description});

  final Widget title;
  final Widget? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: DefaultTextStyle.merge(
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            child: title,
          ),
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            child: description!,
          ),
        ],
      ],
    );
  }
}

const double _splitOuterRadius = 24;
const double _splitInnerRadius = 4;
const double _splitGap = 4;

/// 分组卡片：行与行之间 4dp 间隙，按下时整块圆角收拢。
class SplitListGroup extends StatelessWidget {
  const SplitListGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: _splitGap),
        SplitListRow(
          topRadius: i == 0 ? _splitOuterRadius : _splitInnerRadius,
          bottomRadius: i == children.length - 1
              ? _splitOuterRadius
              : _splitInnerRadius,
          child: children[i],
        ),
      ],
    ],
  );
}

class SplitListRow extends StatefulWidget {
  const SplitListRow({
    super.key,
    required this.child,
    this.topRadius = _splitInnerRadius,
    this.bottomRadius = _splitInnerRadius,
    this.onTap,
  });

  final Widget child;
  final double topRadius;
  final double bottomRadius;
  final VoidCallback? onTap;

  @override
  State<SplitListRow> createState() => _SplitListRowState();
}

class _SplitListRowState extends State<SplitListRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final child = widget.onTap == null
        ? widget.child
        : InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (value) => setState(() => _pressed = value),
            child: widget.child,
          );
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(_pressed ? 20 : widget.topRadius),
          bottom: Radius.circular(_pressed ? 20 : widget.bottomRadius),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTileTheme(
          data: theme.listTileTheme.copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurface,
            ),
            subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 标题 + 分组卡片。
class ContentSection extends StatelessWidget {
  const ContentSection.group({
    super.key,
    required this.title,
    required this.children,
    this.description,
  });

  final String title;
  final List<Widget> children;
  final String? description;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SectionHeader(
          title: Text(title),
          description: description == null ? null : Text(description!),
        ),
      ),
      SplitListGroup(children: children),
    ],
  );
}

/// 分类入口行。
class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: colors.onSurfaceVariant),
      title: Text(title),
      subtitle: Text(description),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// 宽屏设置左侧目录项。
class SettingsRailDestination extends StatelessWidget {
  const SettingsRailDestination({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(icon, size: 24, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
