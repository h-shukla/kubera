import 'dart:convert';
import 'package:capit_n_bulls/providers/auth_provider.dart';
import 'package:capit_n_bulls/providers/live_stocks_provider.dart'; // ← NEW
import 'package:capit_n_bulls/providers/trading_prefs_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'stock.dart';

// ── Contract Info Model ───────────────────────────────────────────────────────

class _ContractInfo {
  final int lotSize;
  final double marginNeeded;
  final double ltp;
  final String ltpStatus;
  final String tradingSymbol;

  const _ContractInfo({
    required this.lotSize,
    required this.marginNeeded,
    required this.ltp,
    required this.ltpStatus,
    required this.tradingSymbol,
  });

  factory _ContractInfo.fromJson(Map<String, dynamic> json) {
    return _ContractInfo(
      lotSize: (json['lot_size'] as num?)?.toInt() ?? 1,
      marginNeeded: (json['margin_needed'] as num?)?.toDouble() ?? 0.0,
      ltp: (json['ltp'] as num?)?.toDouble() ?? 0.0,
      ltpStatus: json['ltp_status']?.toString() ?? 'not_in_feed',
      tradingSymbol: json['trading_symbol']?.toString() ?? '',
    );
  }

  bool get isLive => ltpStatus == 'live';
}

// ── StockDetailSheet ──────────────────────────────────────────────────────────
// Now accepts a token (int) instead of a StockData snapshot.
// It watches liveStocksProvider so bid/ask and all prices update in real-time.

class StockDetailSheet extends ConsumerStatefulWidget {
  /// The instrument token — used to look up live data from the provider.
  final int token;

  /// Fallback snapshot used only if the token isn't in the provider yet
  /// (e.g. the sheet was opened before the next WS tick arrives).
  final StockData fallback;

  const StockDetailSheet({
    super.key,
    required this.token,
    required this.fallback,
  });

  static void show(BuildContext context, StockData stock) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      useSafeArea: true,
      // ProviderScope not needed — sheet is inside the existing scope
      builder: (_) =>
          StockDetailSheet(token: stock.instrumentToken, fallback: stock),
    );
  }

  @override
  ConsumerState<StockDetailSheet> createState() => _StockDetailSheetState();
}

class _StockDetailSheetState extends ConsumerState<StockDetailSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fadeAnim;

  _ContractInfo? _contractInfo;
  bool _contractLoading = true;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
    _loadContractInfo();
  }

  Future<void> _loadContractInfo() async {
    try {
      final response = await http
          .get(Uri.parse('http://69.62.75.117:8765/contract/${widget.token}'))
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _contractInfo = _ContractInfo.fromJson(json);
          _contractLoading = false;
        });
      } else {
        setState(() => _contractLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _contractLoading = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _gainColor => const Color(0xFF3FD47E);
  Color get _lossColor => const Color(0xFFE05252);

  double? _bestBid(StockData s) =>
      s.depthBuy.isNotEmpty ? s.depthBuy.first.price : null;

  double? _bestAsk(StockData s) =>
      s.depthSell.isNotEmpty ? s.depthSell.first.price : null;

  int? _bestBidQty(StockData s) =>
      s.depthBuy.isNotEmpty ? s.depthBuy.first.quantity : null;

  int? _bestAskQty(StockData s) =>
      s.depthSell.isNotEmpty ? s.depthSell.first.quantity : null;

  @override
  Widget build(BuildContext context) {
    // ── Live data: rebuilds on every WS tick for THIS token only ──────────
    final stock =
        ref.watch(liveStocksProvider.select((map) => map[widget.token])) ??
        widget.fallback;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isPositive = stock.changePercent >= 0;
    final accentColor = isPositive ? _gainColor : _lossColor;

    final changeText =
        '${isPositive ? '+' : ''}${stock.changePercent.toStringAsFixed(2)}%';

    return FadeTransition(
      opacity: _fadeAnim,
      child: DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                // ── Drag handle ──
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // ── Scrollable content ──
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    children: [
                      // ── Header ──
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  stock.symbol,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: colorScheme.onSurface,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    stock.exchange,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '₹${stock.formattedPrice}',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isPositive
                                          ? Icons.arrow_upward_rounded
                                          : Icons.arrow_downward_rounded,
                                      color: accentColor,
                                      size: 13,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      changeText,
                                      style: TextStyle(
                                        color: accentColor,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),
                      _divider(theme),
                      const SizedBox(height: 20),

                      // ── Contract info pill (lot size + margin) ──
                      const SizedBox(height: 12),
                      _contractInfoRow(theme, colorScheme),

                      const SizedBox(height: 20),
                      _divider(theme),
                      const SizedBox(height: 20),

                      _sectionLabel('TODAY', theme),
                      const SizedBox(height: 12),
                      _twoColumnGrid([
                        _StatItem(label: 'Open', value: '₹${_fmt(stock.open)}'),
                        _StatItem(
                          label: 'Close',
                          value: '₹${_fmt(stock.close)}',
                        ),
                        _StatItem(
                          label: 'High',
                          value: '₹${_fmt(stock.high)}',
                          valueColor: _gainColor,
                        ),
                        _StatItem(
                          label: 'Low',
                          value: '₹${_fmt(stock.low)}',
                          valueColor: _lossColor,
                        ),
                        _StatItem(
                          label: 'Volume',
                          value: stock.formattedVolume,
                        ),
                      ], theme),

                      const SizedBox(height: 8),
                      _divider(theme),
                      const SizedBox(height: 20),

                      _sectionLabel('MARKET DEPTH', theme),
                      const SizedBox(height: 12),
                      _depthLadder(stock, theme),
                      const SizedBox(height: 20),
                      _divider(theme),
                      const SizedBox(height: 12),

                      _sectionLabel('CIRCUIT LIMITS', theme),
                      const SizedBox(height: 12),
                      _circuitBar(stock, theme),

                      const SizedBox(height: 24),
                      _divider(theme),
                      const SizedBox(height: 20),

                      _sectionLabel('52-WEEK RANGE', theme),
                      const SizedBox(height: 12),
                      _weekRangeBar(stock, theme),

                      const SizedBox(height: 8),
                    ],
                  ),
                ),

                // ── Sticky Buy/Sell Bar ──
                _BuySellBar(
                  stock: stock,
                  contractInfo: _contractInfo,
                  gainColor: _gainColor,
                  lossColor: _lossColor,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Depth Ladder ──────────────────────────────────────────────────────────

  Widget _depthLadder(StockData stock, ThemeData theme) {
    final bids = stock.depthBuy;
    final asks = stock.depthSell;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'BID',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _gainColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'ASK',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: _lossColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        ...List.generate(5, (i) {
          final bid = i < bids.length ? bids[i] : null;
          final ask = i < asks.length ? asks[i] : null;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: _depthCell(
                    price: bid?.price,
                    qty: bid?.quantity,
                    color: _gainColor,
                    alignEnd: false,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _depthCell(
                    price: ask?.price,
                    qty: ask?.quantity,
                    color: _lossColor,
                    alignEnd: true,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _depthCell({
    required double? price,
    required int? qty,
    required Color color,
    required bool alignEnd,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: alignEnd
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!alignEnd) ...[
            Text(
              price != null ? price.toStringAsFixed(2) : '—',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Text(qty != null ? 'Qty: $qty' : '—'),
          ] else ...[
            Text(qty != null ? 'Qty: $qty' : '—'),
            const SizedBox(width: 6),
            Text(
              price != null ? price.toStringAsFixed(2) : '—',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  // ── Contract info row ─────────────────────────────────────────────────────

  Widget _contractInfoRow(ThemeData theme, ColorScheme colorScheme) {
    if (_contractLoading) {
      return Row(
        children: [
          _infoPill(
            icon: Icons.layers_outlined,
            label: 'Lot Size',
            value: '—',
            theme: theme,
            colorScheme: colorScheme,
          ),
          const SizedBox(width: 8),
          _infoPill(
            icon: Icons.account_balance_wallet_outlined,
            label: 'Margin (7×)',
            value: '—',
            theme: theme,
            colorScheme: colorScheme,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      );
    }

    final info = _contractInfo;
    if (info == null) return const SizedBox.shrink();

    return Row(
      children: [
        _infoPill(
          icon: Icons.layers_outlined,
          label: 'Lot Size',
          value: '${info.lotSize}',
          theme: theme,
          colorScheme: colorScheme,
        ),
        const SizedBox(width: 8),
        _infoPill(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Margin (7×)',
          value: info.marginNeeded > 0
              ? '₹${_fmtCompact(info.marginNeeded)}'
              : '—',
          theme: theme,
          colorScheme: colorScheme,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: (info.isLive ? _gainColor : _lossColor).withValues(
              alpha: 0.12,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: info.isLive ? _gainColor : _lossColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                info.isLive ? 'Live' : 'No Feed',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: info.isLive ? _gainColor : _lossColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoPill({
    required IconData icon,
    required String label,
    required String value,
    required ThemeData theme,
    required ColorScheme colorScheme,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmt(double v) => v.toStringAsFixed(2);

  String _fmtCompact(double v) {
    if (v >= 1e7) return '${(v / 1e7).toStringAsFixed(2)}Cr';
    if (v >= 1e5) return '${(v / 1e5).toStringAsFixed(2)}L';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  Widget _divider(ThemeData theme) =>
      Divider(height: 1, color: theme.dividerColor);

  Widget _sectionLabel(String label, ThemeData theme) => Text(
    label,
    style: theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    ),
  );

  Widget _twoColumnGrid(List<_StatItem> items, ThemeData theme) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final left = items[i];
      final right = i + 1 < items.length ? items[i + 1] : null;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              Expanded(child: _statCell(left, theme)),
              if (right != null) Expanded(child: _statCell(right, theme)),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  Widget _statCell(_StatItem item, ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        item.label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        item.value,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: item.valueColor ?? theme.colorScheme.onSurface,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget _circuitBar(StockData stock, ThemeData theme) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _circuitLabel(
              'LC',
              '₹${_fmt(stock.lowerCircuit)}',
              _lossColor,
              theme,
            ),
            _circuitLabel(
              'UC',
              '₹${_fmt(stock.upperCircuit)}',
              _gainColor,
              theme,
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final range = stock.upperCircuit - stock.lowerCircuit;
            final ratio = ((stock.price - stock.lowerCircuit) / range).clamp(
              0.0,
              1.0,
            );
            final dotLeft = (constraints.maxWidth * ratio - 6).clamp(
              0.0,
              constraints.maxWidth - 12,
            );

            return SizedBox(
              height: 12,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 3,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    left: dotLeft,
                    top: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.outline,
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Current ₹${_fmt(stock.price)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _circuitLabel(
    String tag,
    String value,
    Color color,
    ThemeData theme,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          tag,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget _weekRangeBar(StockData stock, ThemeData theme) {
    final range = stock.week52High - stock.week52Low;
    final ratio = ((stock.price - stock.week52Low) / range).clamp(0.0, 1.0);

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final dotLeft = (constraints.maxWidth * ratio - 6).clamp(
              0.0,
              constraints.maxWidth - 12,
            );
            return SizedBox(
              height: 12,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 3,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _lossColor.withValues(alpha: 0.6),
                            _gainColor.withValues(alpha: 0.6),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    left: dotLeft,
                    top: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.outline,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _rangeLabel(
              '52W Low',
              '₹${_fmt(stock.week52Low)}',
              _lossColor,
              theme,
              CrossAxisAlignment.start,
            ),
            _rangeLabel(
              '52W High',
              '₹${_fmt(stock.week52High)}',
              _gainColor,
              theme,
              CrossAxisAlignment.end,
            ),
          ],
        ),
      ],
    );
  }

  Widget _rangeLabel(
    String label,
    String value,
    Color color,
    ThemeData theme,
    CrossAxisAlignment align,
  ) => Column(
    crossAxisAlignment: align,
    children: [
      Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );
}

// ── Buy/Sell Bar ──────────────────────────────────────────────────────────────

class _BuySellBar extends StatelessWidget {
  final StockData stock;
  final _ContractInfo? contractInfo;
  final Color gainColor;
  final Color lossColor;

  const _BuySellBar({
    required this.stock,
    required this.contractInfo,
    required this.gainColor,
    required this.lossColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _OrderButton(
              label: 'BUY',
              color: gainColor,
              stock: stock,
              contractInfo: contractInfo,
              isBuy: true,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _OrderButton(
              label: 'SELL',
              color: lossColor,
              stock: stock,
              contractInfo: contractInfo,
              isBuy: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderButton extends ConsumerWidget {
  final String label;
  final Color color;
  final StockData stock;
  final _ContractInfo? contractInfo;
  final bool isBuy;

  const _OrderButton({
    required this.label,
    required this.color,
    required this.stock,
    required this.contractInfo,
    required this.isBuy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final confirmEnabled =
        ref.watch(tradingPrefsProvider).valueOrNull?.orderConfirmation ?? true;

    return GestureDetector(
      onTap: () {
        if (confirmEnabled) {
          _OrderDialog.show(context, stock, contractInfo, isBuy);
        } else {
          _OrderDialog.showAndAutoConfirm(context, stock, contractInfo, isBuy);
        }
      },
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

// ── Order Dialog ──────────────────────────────────────────────────────────────

class _OrderResult {
  final bool success;
  final String message;
  const _OrderResult({required this.success, required this.message});
}

class _OrderDialog extends ConsumerStatefulWidget {
  final StockData stock;
  final _ContractInfo? contractInfo;
  final bool isBuy;
  final ScaffoldMessengerState messenger;
  final bool autoConfirm;

  const _OrderDialog({
    required this.stock,
    required this.contractInfo,
    required this.isBuy,
    required this.messenger,
    this.autoConfirm = false,
  });

  static void show(
    BuildContext context,
    StockData stock,
    _ContractInfo? contractInfo,
    bool isBuy,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _OrderDialog(
        stock: stock,
        contractInfo: contractInfo,
        isBuy: isBuy,
        messenger: messenger,
      ),
    );
  }

  static void showAndAutoConfirm(
    BuildContext context,
    StockData stock,
    _ContractInfo? contractInfo,
    bool isBuy,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _OrderDialog(
        stock: stock,
        contractInfo: contractInfo,
        isBuy: isBuy,
        messenger: messenger,
        autoConfirm: true,
      ),
    );
  }

  @override
  ConsumerState<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends ConsumerState<_OrderDialog> {
  int _qty = 1;
  String _productType = 'MIS';
  bool _prefsApplied = false;
  bool _isLimitOrder = false;
  final TextEditingController _limitPriceCtrl = TextEditingController();
  bool _isLoading = false;

  int get _lotSize => widget.contractInfo?.lotSize ?? 1;
  int get _actualQty => _qty * _lotSize;

  Color get _accentColor =>
      widget.isBuy ? const Color(0xFF3FD47E) : const Color(0xFFE05252);

  double get _effectivePrice => _isLimitOrder && _limitPriceCtrl.text.isNotEmpty
      ? double.tryParse(_limitPriceCtrl.text) ?? widget.stock.price
      : widget.stock.price;

  double get _total => _actualQty * _effectivePrice;

  String _orderLabelToProductType(String label) =>
      label == 'Intraday' ? 'MIS' : 'NRML';

  @override
  void initState() {
    super.initState();
    _limitPriceCtrl.text = widget.stock.price.toStringAsFixed(2);

    if (widget.autoConfirm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleConfirm();
      });
    }
  }

  @override
  void dispose() {
    _limitPriceCtrl.dispose();
    super.dispose();
  }

  Future<_OrderResult> _placeOrder() async {
    final stock = widget.stock;
    final side = widget.isBuy ? 'BUY' : 'SELL';
    final userId = ref.read(authProvider.notifier).userId ?? 'unknown';

    final body = {
      "user_id": userId,
      "timestamp": DateTime.now().toIso8601String(),
      "total_pnl": 0.0,
      "contract_name": stock.symbol,
      "exchange_token": stock.symbol,
      "qty": _actualQty,
      "lot_size": _lotSize,
      "lots": _qty,
      "side": side,
      "order_type": _productType == "CNC" ? "NRML" : _productType,
      "product_type": _isLimitOrder ? "LIMIT" : "MARKET",
      if (_isLimitOrder) "limit_price": _effectivePrice,
      "entry_price": _effectivePrice,
      "ltp": stock.price,
      "pnl": 0.0,
      "status": _isLimitOrder ? "PENDING" : "OPEN",
    };

    try {
      debugPrint("Order Payload: ${jsonEncode(body)}");

      final accessToken = ref.read(authProvider.notifier).accessToken;
      final response = await http
          .post(
            Uri.parse('http://69.62.75.117:8765/orders'),
            headers: {
              'Content-Type': 'application/json',
              if (accessToken != null) 'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        try {
          debugPrint("Order success: ${jsonDecode(response.body)}");
        } catch (_) {}
        return const _OrderResult(
          success: true,
          message: 'Order placed successfully',
        );
      }

      String errorMsg = 'Server error (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        errorMsg =
            decoded['detail']?.toString() ??
            decoded['message']?.toString() ??
            decoded['error']?.toString() ??
            errorMsg;
        debugPrint("Order error: $decoded");
      } catch (_) {
        debugPrint("Raw error: ${response.body}");
      }

      return _OrderResult(success: false, message: errorMsg);
    } on http.ClientException catch (e) {
      return _OrderResult(
        success: false,
        message: 'Network error: ${e.message}',
      );
    } catch (e) {
      return _OrderResult(success: false, message: 'Unexpected error: $e');
    }
  }

  Future<void> _handleConfirm() async {
    setState(() => _isLoading = true);
    final result = await _placeOrder();
    if (!mounted) return;
    setState(() => _isLoading = false);

    final overlay = Overlay.of(context, rootOverlay: true);
    final bottomPad = MediaQuery.of(context).padding.bottom;

    Navigator.of(context).pop();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: bottomPad + 120,
        left: 16,
        right: 16,
        child: _SnackbarToast(
          success: result.success,
          message: result.success
              ? '${widget.isBuy ? 'Buy' : 'Sell'} order: $_qty lot${_qty > 1 ? 's' : ''} '
                    '($_actualQty qty) of ${widget.stock.symbol} placed'
              : result.message,
          accentColor: result.success
              ? const Color(0xFF3FD47E)
              : const Color(0xFFE05252),
          onDone: () => entry.remove(),
        ),
      ),
    );

    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final prefsAsync = ref.watch(tradingPrefsProvider);
    prefsAsync.whenData((prefs) {
      if (!_prefsApplied) {
        _prefsApplied = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _qty = prefs.defaultQty;
              _productType = _orderLabelToProductType(prefs.defaultOrder);
            });
          }
        });
      }
    });

    final hasLotSize = _lotSize > 1;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: colorScheme.surface,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _accentColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.isBuy ? 'BUY' : 'SELL',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.stock.symbol,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'LTP ₹${widget.stock.formattedPrice}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (hasLotSize) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Lot: $_lotSize',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 20),
              Divider(color: theme.dividerColor),
              const SizedBox(height: 16),

              // ── QUANTITY ──
              Row(
                children: [
                  _dialogLabel(hasLotSize ? 'LOTS' : 'QUANTITY', theme),
                  if (hasLotSize) ...[
                    const Spacer(),
                    Text(
                      'qty: $_actualQty',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _QtyButton(
                    icon: Icons.remove,
                    onTap: () {
                      if (_qty > 1) setState(() => _qty--);
                    },
                  ),
                  Expanded(
                    child: Center(
                      child: Column(
                        children: [
                          Text(
                            '$_qty',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          if (hasLotSize)
                            Text(
                              'lot${_qty > 1 ? 's' : ''}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _QtyButton(
                    icon: Icons.add,
                    onTap: () => setState(() => _qty++),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ── ORDER TYPE ──
              _dialogLabel('ORDER TYPE', theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      'NRML',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Fixed',
                        style: TextStyle(
                          fontSize: 10,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── PRODUCT TYPE ──
              _dialogLabel('PRODUCT TYPE', theme),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ToggleChip(
                    label: 'MIS',
                    subtitle: 'Intraday',
                    selected: _productType == 'MIS',
                    selectedColor: _accentColor,
                    onTap: () => setState(() => _productType = 'MIS'),
                    theme: theme,
                  ),
                  const SizedBox(width: 10),
                  _ToggleChip(
                    label: 'NRML',
                    subtitle: 'Delivery',
                    selected: _productType == 'NRML',
                    selectedColor: _accentColor,
                    onTap: () => setState(() => _productType = 'NRML'),
                    theme: theme,
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ── PRICE TYPE ──
              _dialogLabel('PRICE TYPE', theme),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ToggleChip(
                    label: 'Market',
                    subtitle: 'At LTP',
                    selected: !_isLimitOrder,
                    selectedColor: _accentColor,
                    onTap: () => setState(() => _isLimitOrder = false),
                    theme: theme,
                  ),
                  const SizedBox(width: 10),
                  _ToggleChip(
                    label: 'Limit',
                    subtitle: 'Custom',
                    selected: _isLimitOrder,
                    selectedColor: _accentColor,
                    onTap: () => setState(() => _isLimitOrder = true),
                    theme: theme,
                  ),
                ],
              ),

              if (_isLimitOrder) ...[
                const SizedBox(height: 16),
                _dialogLabel('LIMIT PRICE', theme),
                const SizedBox(height: 8),
                TextField(
                  controller: _limitPriceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixText: '₹ ',
                    prefixStyle: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: colorScheme.outline.withValues(alpha: 0.3),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: colorScheme.outline.withValues(alpha: 0.3),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: _accentColor, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),
              Divider(color: theme.dividerColor),
              const SizedBox(height: 12),

              // ── TOTAL VALUE ──
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Contract Value',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            if (hasLotSize)
                              Text(
                                '$_qty lot${_qty > 1 ? 's' : ''} × $_lotSize × ₹${_effectivePrice.toStringAsFixed(2)}',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.6),
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          '₹${_total.toStringAsFixed(2)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Divider(
                      height: 1,
                      color: colorScheme.outline.withValues(alpha: 0.2),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Margin Required',
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '7× leverage applied',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          () {
                            if (widget.contractInfo != null &&
                                widget.contractInfo!.marginNeeded > 0) {
                              return '₹${(widget.contractInfo!.marginNeeded * _qty).toStringAsFixed(2)}';
                            }
                            // Fallback: derive from total ÷ 7 leverage
                            return '₹${(_total / 7).toStringAsFixed(2)}';
                          }(),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── ACTION BUTTONS ──
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _isLoading
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _isLoading ? null : _handleConfirm,
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: _isLoading
                              ? _accentColor.withValues(alpha: 0.6)
                              : _accentColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Confirm ${widget.isBuy ? 'Buy' : 'Sell'}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogLabel(String label, ThemeData theme) => Text(
    label,
    style: theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    ),
  );
}

// ── Toggle Chip ───────────────────────────────────────────────────────────────

class _ToggleChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;
  final ThemeData theme;

  const _ToggleChip({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = theme.colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? selectedColor.withValues(alpha: 0.12)
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? selectedColor
                  : colorScheme.outline.withValues(alpha: 0.3),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? selectedColor : colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: selected
                      ? selectedColor.withValues(alpha: 0.7)
                      : colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Qty Button ────────────────────────────────────────────────────────────────

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _QtyButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 20, color: colorScheme.onSurface),
      ),
    );
  }
}

// ── Stat Item ─────────────────────────────────────────────────────────────────

class _StatItem {
  final String label;
  final String value;
  final Color? valueColor;
  const _StatItem({required this.label, required this.value, this.valueColor});
}

// ── Snackbar Toast ────────────────────────────────────────────────────────────

class _SnackbarToast extends StatefulWidget {
  final bool success;
  final String message;
  final Color accentColor;
  final VoidCallback onDone;

  const _SnackbarToast({
    required this.success,
    required this.message,
    required this.accentColor,
    required this.onDone,
  });

  @override
  State<_SnackbarToast> createState() => _SnackbarToastState();
}

class _SnackbarToastState extends State<_SnackbarToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();

    Future.delayed(const Duration(seconds: 4), () async {
      if (mounted) {
        await _ctrl.reverse();
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.accentColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                widget.success
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
