import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';

/// ─────────────────────────────────────────────────────────
/// MODEL
/// ─────────────────────────────────────────────────────────

class TradeBookEntry {
  final DateTime tradeDateTime;
  final String symbolName;
  final String symbolCode;
  final String action;
  final int quantity;
  final double tradePrice;
  final String exchange;
  final double? pnl;
  final String leg;

  const TradeBookEntry({
    required this.tradeDateTime,
    required this.symbolName,
    required this.symbolCode,
    required this.action,
    required this.quantity,
    required this.tradePrice,
    required this.exchange,
    required this.leg,
    this.pnl,
  });

  factory TradeBookEntry.fromJson(Map<String, dynamic> json) {
    // Parse timestamp
    final rawDate =
        json['timestamp']?.toString() ??
        json['closed_at']?.toString() ??
        json['updated_at']?.toString() ??
        json['trade_date_time']?.toString() ??
        '';

    final dt = DateTime.tryParse(rawDate)?.toLocal() ?? DateTime.now();

    // Symbol
    final symbol =
        json['contract_name']?.toString() ??
        json['tradingsymbol']?.toString() ??
        '-';

    // Side
    final side =
        json['side']?.toString() ??
        json['action']?.toString() ??
        json['transaction_type']?.toString() ??
        'BUY';

    // Quantity
    final qty =
        (json['qty'] as num?)?.toInt() ??
        int.tryParse(json['quantity']?.toString() ?? '') ??
        int.tryParse(json['lot_size']?.toString() ?? '') ??
        0;

    // IMPORTANT FIX:
    // Use backend-provided exact leg price
    final price = (json['price'] as num?)?.toDouble() ?? 0.0;

    // Exchange
    final exchange = json['exchange']?.toString() ?? '';

    // Leg
    final leg = json['leg']?.toString() ?? '';

    // IMPORTANT FIX:
    // realised_pnl only exists on EXIT leg
    final pnl = json['realised_pnl'] != null
        ? double.tryParse(json['realised_pnl'].toString())
        : null;

    return TradeBookEntry(
      tradeDateTime: dt,
      symbolName: symbol,
      symbolCode: symbol,
      action: side.toUpperCase(),
      quantity: qty,
      tradePrice: price,
      exchange: exchange,
      leg: leg,
      pnl: pnl,
    );
  }
}

/// ─────────────────────────────────────────────────────────
/// API SERVICE
/// ─────────────────────────────────────────────────────────

class TradebookApi {
  static const String baseUrl = 'http://69.62.75.117:8765';

  static Future<List<TradeBookEntry>> fetchTrades(String userId) async {
    final url = Uri.parse('$baseUrl/tradebook/$userId');

    final response = await http
        .get(url, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Failed: ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);

    // DEBUG PRINT
    debugPrint("TRADEBOOK API RESPONSE:");
    debugPrint(const JsonEncoder.withIndent('  ').convert(decoded));

    // API returns { trades: [...] }
    if (decoded is Map && decoded['trades'] is List) {
      return (decoded['trades'] as List)
          .map((e) => TradeBookEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Fallback: top-level list
    if (decoded is List) {
      return decoded
          .map((e) => TradeBookEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Fallback: data key
    if (decoded is Map && decoded['data'] is List) {
      return (decoded['data'] as List)
          .map((e) => TradeBookEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return [];
  }
}

/// ─────────────────────────────────────────────────────────
/// PROVIDER
/// ─────────────────────────────────────────────────────────

final tradebookProvider = FutureProvider<List<TradeBookEntry>>((ref) async {
  final userId = ref.read(authProvider.notifier).userId ?? 'unknown';
  return TradebookApi.fetchTrades(userId);
});

/// ─────────────────────────────────────────────────────────
/// FORMATTERS
/// ─────────────────────────────────────────────────────────

String _formatTimeShort(DateTime dt) {
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

String _formatDateFull(DateTime dt) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
}

String _formatTimeFull(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  final ms = dt.millisecond.toString().padLeft(3, '0');

  return '$h:$m:$s.$ms';
}

/// ─────────────────────────────────────────────────────────
/// DETAILS POPUP
/// ─────────────────────────────────────────────────────────

void _showTradeDetail(BuildContext context, TradeBookEntry entry) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final isBuy = entry.action.toLowerCase() == 'buy';
  final totalValue = entry.tradePrice * entry.quantity;

  showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
    builder: (_) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.symbolName,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      if (entry.exchange.isNotEmpty)
                        Text(
                          entry.exchange,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? Colors.grey.shade400
                                : Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: isBuy
                        ? Colors.green.withOpacity(0.15)
                        : Colors.red.withOpacity(0.15),
                  ),
                  child: Text(
                    entry.action.toUpperCase(),
                    style: TextStyle(
                      color: isBuy ? Colors.green : Colors.red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            _DetailRow(
              label: 'Date',
              value: _formatDateFull(entry.tradeDateTime),
            ),

            const SizedBox(height: 12),

            _DetailRow(
              label: 'Exact Time',
              value: _formatTimeFull(entry.tradeDateTime),
              valueMono: true,
            ),

            const SizedBox(height: 12),

            _DetailRow(
              label: 'Trade Price',
              value: '₹${entry.tradePrice.toStringAsFixed(2)}',
            ),

            const SizedBox(height: 12),

            _DetailRow(label: 'Quantity', value: '${entry.quantity}'),

            const SizedBox(height: 12),

            _DetailRow(label: 'Leg', value: entry.leg),

            const SizedBox(height: 12),

            _DetailRow(
              label: 'Total Value',
              value: '₹${totalValue.toStringAsFixed(2)}',
              valueBold: true,
            ),

            if (entry.leg == 'EXIT' && entry.pnl != null) ...[
              const SizedBox(height: 12),

              _DetailRow(
                label: 'Realised P&L',
                value: entry.pnl! >= 0
                    ? '+₹${entry.pnl!.toStringAsFixed(2)}'
                    : '-₹${entry.pnl!.abs().toStringAsFixed(2)}',
                valueBold: true,
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool valueBold;
  final bool valueMono;

  const _DetailRow({
    required this.label,
    required this.value,
    this.valueBold = false,
    this.valueMono = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade500)),
        Text(
          value,
          style: TextStyle(
            fontWeight: valueBold ? FontWeight.w700 : FontWeight.w600,
            fontFamily: valueMono ? 'monospace' : null,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ],
    );
  }
}

/// ─────────────────────────────────────────────────────────
/// SCREEN
/// ─────────────────────────────────────────────────────────

class TradeBookScreen extends ConsumerStatefulWidget {
  const TradeBookScreen({super.key});

  @override
  ConsumerState<TradeBookScreen> createState() => _TradeBookScreenState();
}

class _TradeBookScreenState extends ConsumerState<TradeBookScreen> {
  @override
  void initState() {
    super.initState();

    Future.microtask(() {
      ref.invalidate(tradebookProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tradesAsync = ref.watch(tradebookProvider);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final borderColor = isDark ? Colors.white10 : const Color(0xFFE5E5E7);

    final headerColor = isDark
        ? const Color(0xFF1E1E1E)
        : const Color(0xFFF4F4F5);

    return Container(
      color: isDark ? const Color(0xFF121212) : Colors.white,

      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),

      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),

        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),

          child: Column(
            children: [
              Container(
                color: headerColor,

                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),

                child: Row(
                  children: const [
                    _HeaderCell(label: 'Trade\nTime', flex: 2),
                    _HeaderCell(label: 'Symbol', flex: 3),
                    _HeaderCell(label: 'Buy/Sell', flex: 3),
                    _HeaderCell(
                      label: 'Trade\nPrice',
                      flex: 2,
                      align: TextAlign.right,
                    ),
                  ],
                ),
              ),

              Divider(height: 1, thickness: 1, color: borderColor),

              Expanded(
                child: tradesAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),

                  error: (e, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        e.toString(),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                    ),
                  ),

                  data: (trades) {
                    if (trades.isEmpty) {
                      return Center(
                        child: Text(
                          'No trades found',
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: () async {
                        ref.invalidate(tradebookProvider);
                        await ref.read(tradebookProvider.future);
                      },

                      child: ListView.separated(
                        itemCount: trades.length,

                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          thickness: 1,
                          color: borderColor,
                        ),

                        itemBuilder: (context, index) {
                          final trade = trades[index];

                          return _TradeRow(
                            entry: trade,
                            onTap: () => _showTradeDetail(context, trade),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final int flex;
  final TextAlign align;

  const _HeaderCell({
    required this.label,
    required this.flex,
    this.align = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Expanded(
      flex: flex,

      child: Text(
        label,
        textAlign: align,

        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.grey.shade500 : Colors.grey.shade700,
        ),
      ),
    );
  }
}

class _TradeRow extends StatelessWidget {
  final TradeBookEntry entry;
  final VoidCallback onTap;

  const _TradeRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isBuy = entry.action.toLowerCase() == 'buy';

    return InkWell(
      onTap: onTap,

      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),

        child: Row(
          children: [
            Expanded(
              flex: 2,

              child: Text(
                _formatTimeShort(entry.tradeDateTime),

                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ),

            Expanded(
              flex: 3,

              child: Text(
                entry.symbolName,

                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),

            Expanded(
              flex: 3,

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  Text(
                    '${entry.action} ${entry.quantity}',

                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isBuy
                          ? const Color(0xFF81C784)
                          : const Color(0xFFE57373),
                    ),
                  ),

                  if (entry.leg == 'EXIT' && entry.pnl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),

                      child: Text(
                        entry.pnl! >= 0
                            ? '+₹${entry.pnl!.toStringAsFixed(2)}'
                            : '-₹${entry.pnl!.abs().toStringAsFixed(2)}',

                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: entry.pnl! >= 0 ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            Expanded(
              flex: 2,

              child: Text(
                '₹${entry.tradePrice.toStringAsFixed(2)}',

                textAlign: TextAlign.right,

                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
