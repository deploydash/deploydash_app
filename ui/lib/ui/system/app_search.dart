import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/local_search_index.dart';
import 'app_theme.dart';

/// Compact search input used in the navigation rail.
class AppSearchField extends StatelessWidget {
  /// Creates the search input.
  const AppSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hintText = 'Search servers and projects',
    this.onChanged,
    this.onClear,
  });

  /// The query text. Owned by the caller, so the field can be cleared from
  /// outside -- which is what closing the overlay does.
  final TextEditingController controller;

  /// The field's focus. Also what `Ctrl/Cmd+K` targets.
  final FocusNode focusNode;

  /// The placeholder, naming what can be found here.
  final String hintText;

  /// Called on every keystroke, so results update as the user types.
  final ValueChanged<String>? onChanged;

  /// Called by the clear button, which appears only once there is text.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      key: const Key('app-search-field'),
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: hintText,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 34,
          minHeight: 34,
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                key: const Key('app-search-clear-button'),
                icon: const Icon(
                  Icons.close,
                  size: 16,
                  semanticLabel: 'Clear search',
                ),
                tooltip: 'Clear search',
                onPressed: onClear,
              ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
      ),
    );
  }
}

/// Search field plus an anchored results panel.
///
/// Owns the query text, the highlighted row, and keyboard navigation. Results
/// come from [resultsBuilder] so this widget stays free of data access.
class AppSearchOverlay extends StatefulWidget {
  /// Creates the search field and its results panel.
  const AppSearchOverlay({
    super.key,
    required this.focusNode,
    required this.resultsBuilder,
    required this.onSelected,
    this.panelWidth = 420,
    this.collapsed = false,
  });

  /// The search field's focus. Focusing it opens the panel, and
  /// `Ctrl/Cmd+K` focuses it from anywhere in the app.
  final FocusNode focusNode;

  /// Produces results for a query.
  ///
  /// A callback rather than a repository, so this widget reaches no data
  /// layer -- `ui` may not import below `services`, and a search box has no
  /// business knowing where servers are stored.
  final List<LocalSearchResult> Function(String query) resultsBuilder;

  /// Called with the chosen result, after the panel has closed.
  final ValueChanged<LocalSearchResult> onSelected;

  /// The panel's width in logical pixels.
  final double panelWidth;

  /// When true the rail is narrow, so only an icon button is shown.
  final bool collapsed;

  @override
  State<AppSearchOverlay> createState() => _AppSearchOverlayState();
}

class _AppSearchOverlayState extends State<AppSearchOverlay> {
  final TextEditingController _controller = TextEditingController();
  final OverlayPortalController _portalController = OverlayPortalController();
  final ScrollController _scrollController = ScrollController();
  List<LocalSearchResult> _results = const <LocalSearchResult>[];
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (widget.focusNode.hasFocus && !_portalController.isShowing) {
      _portalController.show();
      setState(() {});
    }
  }

  /// Opens the panel first so the collapsed rail has a field to focus.
  void _openFromIcon() {
    if (!_portalController.isShowing) {
      _portalController.show();
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.focusNode.requestFocus();
      }
    });
  }

  void _handleQueryChanged(String query) {
    setState(() {
      _results = widget.resultsBuilder(query);
      _highlightedIndex = 0;
    });
  }

  void _close() {
    _controller.clear();
    setState(() {
      _results = const <LocalSearchResult>[];
      _highlightedIndex = 0;
    });
    if (_portalController.isShowing) {
      _portalController.hide();
    }
  }

  void _moveHighlight(int delta) {
    if (_results.isEmpty) {
      return;
    }
    setState(() {
      _highlightedIndex = (_highlightedIndex + delta) % _results.length;
    });
    _scrollHighlightIntoView();
  }

  void _scrollHighlightIntoView() {
    if (!_scrollController.hasClients) {
      return;
    }
    const rowExtent = 56.0;
    final target = _highlightedIndex * rowExtent;
    final viewport = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    if (target < offset) {
      _scrollController.jumpTo(target);
    } else if (target + rowExtent > offset + viewport) {
      _scrollController.jumpTo(
        (target + rowExtent - viewport).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ),
      );
    }
  }

  void _activateHighlight() {
    if (_results.isEmpty) {
      return;
    }
    final selected = _results[_highlightedIndex];
    _close();
    widget.onSelected(selected);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveHighlight(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveHighlight(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _activateHighlight();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _close();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portalController,
      overlayChildBuilder: (overlayContext) {
        final query = _controller.text.trim();
        if (query.isEmpty && !widget.collapsed) {
          return const SizedBox.shrink();
        }
        // The anchor comes from *this* state's render box, not the overlay's,
        // so it is resolved here and handed to the panel as a value.
        final renderBox = context.findRenderObject() as RenderBox?;
        final anchor = renderBox == null || !renderBox.hasSize
            ? Offset.zero
            : renderBox.localToGlobal(Offset(0, renderBox.size.height + 4));
        return _SearchPanel(
          anchor: anchor,
          panelWidth: widget.panelWidth,
          collapsed: widget.collapsed,
          query: query,
          controller: _controller,
          focusNode: widget.focusNode,
          scrollController: _scrollController,
          results: _results,
          highlightedIndex: _highlightedIndex,
          onQueryChanged: _handleQueryChanged,
          onClose: _close,
          onSelected: (result) {
            _close();
            widget.onSelected(result);
          },
        );
      },
      child: Focus(
        onKeyEvent: _handleKey,
        skipTraversal: true,
        canRequestFocus: false,
        child: widget.collapsed
            ? IconButton(
                key: const Key('app-search-icon-button'),
                icon: const Icon(
                  Icons.search,
                  size: 18,
                  semanticLabel: 'Search servers and projects',
                ),
                tooltip: 'Search servers and projects',
                onPressed: _openFromIcon,
              )
            : AppSearchField(
                controller: _controller,
                focusNode: widget.focusNode,
                onChanged: _handleQueryChanged,
                onClear: _close,
              ),
      ),
    );
  }

  static String _sectionLabel(LocalSearchResultKind kind) {
    return switch (kind) {
      LocalSearchResultKind.server => 'Servers',
      LocalSearchResultKind.project => 'Projects',
      LocalSearchResultKind.screen => 'Screens',
    };
  }
}

class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    required this.anchor,
    required this.panelWidth,
    required this.collapsed,
    required this.query,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.results,
    required this.highlightedIndex,
    required this.onQueryChanged,
    required this.onClose,
    required this.onSelected,
  });

  final Offset anchor;
  final double panelWidth;
  final bool collapsed;
  final String query;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final List<LocalSearchResult> results;
  final int highlightedIndex;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClose;
  final ValueChanged<LocalSearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    // One owner of the panel's hint/empty message block: same padding and
    // text style, parameterized only by key and text.
    Widget panelMessage({required Key key, required String text}) {
      return Padding(
        key: key,
        padding: EdgeInsets.all(tokens.spaceMd),
        child: Text(text, style: theme.textTheme.bodySmall),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('app-search-dismiss-barrier'),
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: anchor.dx,
          top: anchor.dy,
          width: panelWidth,
          child: Material(
            key: const Key('app-search-overlay'),
            color: appSurfaceColor(theme),
            elevation: 8,
            borderRadius: BorderRadius.circular(tokens.radiusMd),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 380),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(tokens.radiusMd),
                border: Border.all(color: appBorderColor(theme)),
              ),
              padding: EdgeInsets.symmetric(vertical: tokens.spaceXs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (collapsed)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        tokens.spaceSm,
                        tokens.spaceXs,
                        tokens.spaceSm,
                        tokens.spaceXs,
                      ),
                      child: AppSearchField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: onQueryChanged,
                        onClear: onClose,
                      ),
                    ),
                  if (query.isEmpty)
                    panelMessage(
                      key: const Key('app-search-hint'),
                      text: 'Type to find a server, project, or screen.',
                    )
                  else if (results.isEmpty)
                    panelMessage(
                      key: const Key('app-search-empty'),
                      text: 'No matches for "$query".',
                    )
                  else
                    Flexible(
                      child: ListView(
                        controller: scrollController,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: _rows(theme, tokens),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _rows(ThemeData theme, AppThemeTokens tokens) {
    final rows = <Widget>[];
    LocalSearchResultKind? lastKind;
    for (var index = 0; index < results.length; index++) {
      final result = results[index];
      if (result.kind != lastKind) {
        lastKind = result.kind;
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceMd,
              tokens.spaceXs,
              tokens.spaceMd,
              4,
            ),
            child: Text(
              _AppSearchOverlayState._sectionLabel(result.kind),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }
      rows.add(
        _AppSearchResultRow(
          rowKey: Key('app-search-result-${result.kind.name}-$index'),
          result: result,
          highlighted: index == highlightedIndex,
          onTap: () => onSelected(result),
        ),
      );
    }
    return rows;
  }
}

class _AppSearchResultRow extends StatelessWidget {
  const _AppSearchResultRow({
    required this.rowKey,
    required this.result,
    required this.highlighted,
    required this.onTap,
  });

  final Key rowKey;
  final LocalSearchResult result;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    final detail = [
      result.subtitle,
      result.context,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' - ');
    return Semantics(
      selected: highlighted,
      child: Material(
        color: highlighted
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        child: InkWell(
          key: rowKey,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spaceMd,
              vertical: tokens.spaceXs,
            ),
            child: Row(
              children: [
                Icon(_iconFor(result.kind), size: 18),
                SizedBox(width: tokens.spaceXs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(LocalSearchResultKind kind) {
    return switch (kind) {
      LocalSearchResultKind.server => Icons.dns_outlined,
      LocalSearchResultKind.project => Icons.folder_outlined,
      LocalSearchResultKind.screen => Icons.chevron_right,
    };
  }
}
