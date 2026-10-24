import 'package:flutter/material.dart';

/// One destination in a workspace's contextual navigation.
@immutable
class AppContextNavigationItem {
  /// Creates a navigation entry.
  const AppContextNavigationItem({
    required this.id,
    required this.label,
    required this.icon,
  });

  /// Stable id, used to build the widget keys the E2E runners drive the app
  /// by -- so renaming a tab does not break a runner.
  final String id;

  /// The tab's title, in sentence case.
  final String label;

  /// The icon shown beside it in the vertical layout.
  final IconData icon;
}

/// The shared contextual navigation used by project, server and settings
/// workspaces.
///
/// One widget for both layouts: a vertical list when there is room, and a
/// horizontal scrolling strip with paging arrows when there is not. Keeping
/// them in one place is what stops the three workspaces growing three
/// slightly different navigations.
///
/// The selected item is always scrolled into view when the strip is
/// horizontal, including at the moment the arrows first appear -- otherwise
/// opening a project on a narrow window can leave the current tab off-screen
/// with nothing to say so.
class AppContextNavigation extends StatefulWidget {
  /// Creates the navigation.
  const AppContextNavigation({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.axis,
    required this.keyNamespace,
  });

  /// The destinations, in display order.
  final List<AppContextNavigationItem> items;

  /// Which one is current, by index into [items].
  final int selectedIndex;

  /// Called with the index the user chose.
  final ValueChanged<int> onSelected;

  /// [Axis.vertical] for a side list, [Axis.horizontal] for a scrolling
  /// strip. The caller decides from the available width.
  final Axis axis;

  /// Prefix for every widget key this builds, so two navigations on screen at
  /// once keep distinct keys and the E2E runners can address each.
  final String keyNamespace;

  @override
  State<AppContextNavigation> createState() => _AppContextNavigationState();
}

class _AppContextNavigationState extends State<AppContextNavigation> {
  late List<GlobalKey> _itemKeys;
  final ScrollController _horizontalScrollController = ScrollController();
  bool _canScrollPrevious = false;
  bool _canScrollNext = false;
  bool _shouldEnsureSelectedVisible = true;

  @override
  void initState() {
    super.initState();
    _itemKeys = _buildKeys();
    _horizontalScrollController.addListener(_updateScrollControls);
  }

  @override
  void didUpdateWidget(covariant AppContextNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        oldWidget.keyNamespace != widget.keyNamespace) {
      _itemKeys = _buildKeys();
      _shouldEnsureSelectedVisible = true;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.axis != widget.axis) {
      _shouldEnsureSelectedVisible = true;
    }
  }

  @override
  void dispose() {
    _horizontalScrollController
      ..removeListener(_updateScrollControls)
      ..dispose();
    super.dispose();
  }

  List<GlobalKey> _buildKeys() => List<GlobalKey>.generate(
    widget.items.length,
    (index) => GlobalKey(
      debugLabel: '${widget.keyNamespace}-${widget.items[index].id}',
    ),
  );

  void _ensureSelectedVisible() {
    if (!_shouldEnsureSelectedVisible ||
        widget.axis != Axis.horizontal ||
        widget.selectedIndex < 0 ||
        widget.selectedIndex >= _itemKeys.length) {
      return;
    }
    _shouldEnsureSelectedVisible = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final selectedContext = _itemKeys[widget.selectedIndex].currentContext;
      if (selectedContext != null) {
        final renderObject = selectedContext.findRenderObject();
        if (renderObject != null && _horizontalScrollController.hasClients) {
          _horizontalScrollController.position
              .ensureVisible(
                renderObject,
                alignment: 0.5,
                duration: Duration.zero,
              )
              .then((_) => _updateScrollControls());
        }
      }
    });
  }

  void _updateScrollControls() {
    if (!mounted || !_horizontalScrollController.hasClients) {
      return;
    }
    final position = _horizontalScrollController.position;
    final canScrollPrevious = position.pixels > 0.5;
    final canScrollNext = position.pixels < position.maxScrollExtent - 0.5;
    if (canScrollPrevious == _canScrollPrevious &&
        canScrollNext == _canScrollNext) {
      return;
    }
    final controlsAreAppearing =
        !_canScrollPrevious &&
        !_canScrollNext &&
        (canScrollPrevious || canScrollNext);
    setState(() {
      _canScrollPrevious = canScrollPrevious;
      _canScrollNext = canScrollNext;
      if (controlsAreAppearing) {
        _shouldEnsureSelectedVisible = true;
      }
    });
  }

  Future<void> _scrollHorizontally(double direction) async {
    if (!_horizontalScrollController.hasClients) {
      return;
    }
    final position = _horizontalScrollController.position;
    final distance = position.viewportDimension * 0.7 * direction;
    final target = (position.pixels + distance).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _horizontalScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureSelectedVisible();
    if (widget.axis == Axis.horizontal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScrollControls();
      });
      return SizedBox(
        height: 52,
        child: Row(
          children: [
            if (_canScrollPrevious || _canScrollNext)
              _ScrollButton(
                keyNamespace: widget.keyNamespace,
                keySuffix: 'previous',
                tooltip: 'Previous sections',
                icon: Icons.chevron_left,
                onPressed: _canScrollPrevious
                    ? () => _scrollHorizontally(-1)
                    : null,
              ),
            Expanded(
              child: SingleChildScrollView(
                key: Key(
                  'app-context-navigation-${widget.keyNamespace}-horizontal',
                ),
                controller: _horizontalScrollController,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < widget.items.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 4),
                      _NavigationItem(
                        key: _itemKeys[index],
                        item: widget.items[index],
                        index: index,
                        selected: index == widget.selectedIndex,
                        compact: true,
                        keyNamespace: widget.keyNamespace,
                        onSelected: widget.onSelected,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_canScrollPrevious || _canScrollNext)
              _ScrollButton(
                keyNamespace: widget.keyNamespace,
                keySuffix: 'next',
                tooltip: 'More sections',
                icon: Icons.chevron_right,
                onPressed: _canScrollNext ? () => _scrollHorizontally(1) : null,
              ),
          ],
        ),
      );
    }

    return SizedBox(
      width: 188,
      child: ListView.separated(
        key: Key('app-context-navigation-${widget.keyNamespace}-vertical'),
        padding: const EdgeInsets.fromLTRB(0, 4, 12, 12),
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) => _NavigationItem(
          key: _itemKeys[index],
          item: widget.items[index],
          index: index,
          selected: index == widget.selectedIndex,
          compact: false,
          keyNamespace: widget.keyNamespace,
          onSelected: widget.onSelected,
        ),
      ),
    );
  }
}

class _ScrollButton extends StatelessWidget {
  const _ScrollButton({
    required this.keyNamespace,
    required this.keySuffix,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String keyNamespace;
  final String keySuffix;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 44,
      child: IconButton(
        key: Key('app-context-navigation-$keyNamespace-$keySuffix'),
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 18, semanticLabel: tooltip),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    super.key,
    required this.item,
    required this.index,
    required this.selected,
    required this.compact,
    required this.keyNamespace,
    required this.onSelected,
  });

  final AppContextNavigationItem item;
  final int index;
  final bool selected;
  final bool compact;
  final String keyNamespace;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectionColor = theme.colorScheme.primary;
    final foreground = selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    final background = selected
        ? Color.alphaBlend(
            selectionColor.withValues(alpha: 0.14),
            theme.colorScheme.surface,
          )
        : Colors.transparent;
    final borderColor = selected
        ? selectionColor.withValues(alpha: 0.42)
        : Colors.transparent;

    return Semantics(
      identifier: '$keyNamespace-nav-${item.id}',
      button: true,
      selected: selected,
      label: item.label,
      child: Material(
        key: Key('$keyNamespace-nav-${item.id}-surface'),
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('$keyNamespace-nav-${item.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSelected(index),
          child: Tab(
            height: 44,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
              child: Row(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  if (!compact) ...[
                    Container(
                      key: Key('$keyNamespace-nav-${item.id}-selection-marker'),
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: selected ? selectionColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      item.icon,
                      size: 18,
                      color: selected ? selectionColor : foreground,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
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
}
