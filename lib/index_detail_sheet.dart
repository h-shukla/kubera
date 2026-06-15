import 'dart:convert';
import 'package:capit_n_bulls/providers/auth_provider.dart';
import 'package:capit_n_bulls/providers/live_indices_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import './stock.dart';

// ── IndexDetailSheet ──────────────────────────────────────────────────────────

class IndexDetailSheet extends ConsumerStatefulWidget {
  final String indexName;
  final IndexData fallback;

  const IndexDetailSheet({
    super.key,
    required this.indexName,
    required this.fallback,
  });

  static void show(BuildContext context, IndexData indexData) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      useSafeArea: true,
      builder: (_) =>
          IndexDetailSheet(indexName: indexData.name, fallback: indexData),
    );
  }

  @override
  ConsumerState<IndexDetailSheet> createState() => _IndexDetailSheetState();
}

class _IndexDetailSheetState extends ConsumerState<IndexDetailSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _gainColor => const Color(0xFF3FD47E);
  Color get _lossColor => const Color(0xFFE05252);

  @override
  Widget build(BuildContext context) {
    final data =
        ref.watch(liveIndicesProvider)[widget.indexName] ?? widget.fallback;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accentColor = data.isPositive ? _gainColor : _lossColor;

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
                                  data.name,
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
                                    'NSE INDEX',
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
                                data.value,
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
                                      data.isPositive
                                          ? Icons.arrow_upward_rounded
                                          : Icons.arrow_downward_rounded,
                                      color: accentColor,
                                      size: 13,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      data.change,
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

                      // ── TODAY ──
                      _sectionLabel('TODAY', theme),
                      const SizedBox(height: 12),
                      _twoColumnGrid([
                        _StatItem(label: 'Open', value: data.open ?? '—'),
                        _StatItem(
                          label: 'Prev Close',
                          value: data.prevClose ?? '—',
                        ),
                        _StatItem(
                          label: 'High',
                          value: data.high ?? '—',
                          valueColor: _gainColor,
                        ),
                        _StatItem(
                          label: 'Low',
                          value: data.low ?? '—',
                          valueColor: _lossColor,
                        ),
                      ], theme),

                      _divider(theme),
                      const SizedBox(height: 20),

                      // ── MARGIN INFO ──
                      _sectionLabel('MARGIN', theme),
                      const SizedBox(height: 12),
                      _marginRow(data, theme, colorScheme),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),

                // ── Sticky Buy/Sell Bar ──
                _BuySellBar(
                  indexName: widget.indexName,
                  fallback: widget.fallback,
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

  // ── Helpers ────────────────────────────────────────────────────────────────

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

  Widget _marginRow(IndexData data, ThemeData theme, ColorScheme colorScheme) {
    final ltp = double.tryParse(data.value.replaceAll(',', ''));
    final lotSize = _lotSizeForIndex(data.name);
    final marginPerLot = (ltp != null) ? (ltp * lotSize) / 7 : null;

    String fmtCompact(double v) {
      if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)}Cr';
      if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)}L';
      if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
      return '₹${v.toStringAsFixed(0)}';
    }

    return Row(
      children: [
        _infoPill(
          icon: Icons.layers_outlined,
          label: 'Lot Size',
          value: '$lotSize',
          theme: theme,
          colorScheme: colorScheme,
        ),
        const SizedBox(width: 8),
        _infoPill(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Margin (7×)',
          value: marginPerLot != null ? fmtCompact(marginPerLot) : '—',
          theme: theme,
          colorScheme: colorScheme,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: _gainColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _gainColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                'Live',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _gainColor,
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
}

// ── Lot size lookup ───────────────────────────────────────────────────────────
// Add more entries here as needed.
int _lotSizeForIndex(String name) {
  final upper = name.toUpperCase();
  if (upper.contains('BANKNIFTY')) return 30;
  return 65; // NIFTY and everything else
}

// ── Buy/Sell Bar ──────────────────────────────────────────────────────────────

class _BuySellBar extends StatelessWidget {
  final String indexName;
  final IndexData fallback;
  final Color gainColor;
  final Color lossColor;

  const _BuySellBar({
    required this.indexName,
    required this.fallback,
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
              indexName: indexName,
              fallback: fallback,
              isBuy: true,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _OrderButton(
              label: 'SELL',
              color: lossColor,
              indexName: indexName,
              fallback: fallback,
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
  final String indexName;
  final IndexData fallback;
  final bool isBuy;

  const _OrderButton({
    required this.label,
    required this.color,
    required this.indexName,
    required this.fallback,
    required this.isBuy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexData = ref.watch(liveIndicesProvider)[indexName] ?? fallback;

    return GestureDetector(
      onTap: () => _IndexOrderDialog.show(context, indexName, indexData, isBuy),
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

// ── Order Result ──────────────────────────────────────────────────────────────

class _OrderResult {
  final bool success;
  final String message;
  const _OrderResult({required this.success, required this.message});
}

// ── Order Dialog ──────────────────────────────────────────────────────────────

class _IndexOrderDialog extends ConsumerStatefulWidget {
  final String indexName;
  final IndexData fallback;
  final bool isBuy;

  const _IndexOrderDialog({
    required this.indexName,
    required this.fallback,
    required this.isBuy,
  });

  static void show(
    BuildContext context,
    String indexName,
    IndexData fallback,
    bool isBuy,
  ) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _IndexOrderDialog(
        indexName: indexName,
        fallback: fallback,
        isBuy: isBuy,
      ),
    );
  }

  @override
  ConsumerState<_IndexOrderDialog> createState() => _IndexOrderDialogState();
}

class _IndexOrderDialogState extends ConsumerState<_IndexOrderDialog> {
  int _qty = 1;
  bool _isLoading = false;
  bool _isLimitOrder = false;
  late final TextEditingController _limitPriceCtrl;

  int get _lotSize => _lotSizeForIndex(widget.indexName);
  int get _actualQty => _qty * _lotSize;

  Color get _accentColor =>
      widget.isBuy ? const Color(0xFF3FD47E) : const Color(0xFFE05252);

  IndexData get _currentData =>
      ref.read(liveIndicesProvider)[widget.indexName] ?? widget.fallback;

  double get _effectiveLtp {
    final raw = _currentData.value.replaceAll(',', '');
    return double.tryParse(raw) ?? 0.0;
  }

  double get _effectivePrice => _isLimitOrder && _limitPriceCtrl.text.isNotEmpty
      ? double.tryParse(_limitPriceCtrl.text) ?? _effectiveLtp
      : _effectiveLtp;

  @override
  void initState() {
    super.initState();
    _limitPriceCtrl = TextEditingController(
      text: _effectiveLtp.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _limitPriceCtrl.dispose();
    super.dispose();
  }

  Future<_OrderResult> _placeOrder() async {
    final indexData = _currentData;
    final side = widget.isBuy ? 'BUY' : 'SELL';
    final userId = ref.read(authProvider.notifier).userId ?? 'unknown';

    final body = {
      "user_id": userId,
      "timestamp": DateTime.now().toIso8601String(),
      "contract_name": indexData.name,
      "exchange_token": indexData.name,
      "qty": _actualQty,
      "lots": _qty,
      "lot_size": _lotSize,
      "side": side,
      "order_type": "MIS",
      "product_type": _isLimitOrder ? "LIMIT" : "MARKET",
      if (_isLimitOrder) "limit_price": _effectivePrice,
      "entry_price": _effectivePrice,
      "ltp": _effectiveLtp,
      "pnl": 0.0,
      "status": _isLimitOrder ? "PENDING" : "OPEN",
    };

    try {
      debugPrint("Index Order Payload: ${jsonEncode(body)}");

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
          debugPrint("Index order success: ${jsonDecode(response.body)}");
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
        debugPrint("Index order error: $decoded");
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
                    '($_actualQty qty) of ${widget.indexName} placed'
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

    final indexData =
        ref.watch(liveIndicesProvider)[widget.indexName] ?? widget.fallback;

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
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      indexData.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'LTP ${indexData.value}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
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
              ),

              const SizedBox(height: 20),
              Divider(color: theme.dividerColor),
              const SizedBox(height: 16),

              // ── QUANTITY ──
              Row(
                children: [
                  _dialogLabel('LOTS', theme),
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

              // ── CONTRACT VALUE ──
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
                    // ── Contract Value ──
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
                            Text(
                              '$_qty lot${_qty > 1 ? 's' : ''} × $_lotSize × ${_effectivePrice.toStringAsFixed(2)}',
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
                            final total = _actualQty * _effectivePrice;
                            if (total >= 1e7)
                              return '₹${(total / 1e7).toStringAsFixed(2)}Cr';
                            if (total >= 1e5)
                              return '₹${(total / 1e5).toStringAsFixed(2)}L';
                            return '₹${total.toStringAsFixed(2)}';
                          }(),
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

                    // ── Margin Required ──
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
                            final margin = (_actualQty * _effectivePrice) / 7;
                            if (margin >= 1e7)
                              return '₹${(margin / 1e7).toStringAsFixed(2)}Cr';
                            if (margin >= 1e5)
                              return '₹${(margin / 1e5).toStringAsFixed(2)}L';
                            if (margin >= 1e3)
                              return '₹${(margin / 1e3).toStringAsFixed(1)}K';
                            return '₹${margin.toStringAsFixed(2)}';
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
