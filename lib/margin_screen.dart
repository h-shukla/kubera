import 'dart:async';
import 'dart:convert';

import 'package:capit_n_bulls/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

class WalletData {
  final double balance;
  final double marginUsed;
  final double available;
  final double realisedPnl;

  const WalletData({
    required this.balance,
    required this.marginUsed,
    required this.available,
    required this.realisedPnl,
  });

  factory WalletData.fromJson(Map<String, dynamic> json) => WalletData(
    balance: (json['balance'] as num).toDouble(),
    marginUsed: (json['margin_used'] as num).toDouble(),
    available: (json['available'] as num).toDouble(),
    realisedPnl: (json['realised_pnl'] as num).toDouble(),
  );
}

class PositionData {
  final String contractName;
  final String exchangeToken;
  final int buyQty;
  final int sellQty;
  final int netQty;
  final double avgEntryPrice;
  final double totalMargin;
  final double? ltp;
  final double? unrealisedPnl;

  const PositionData({
    required this.contractName,
    required this.exchangeToken,
    required this.buyQty,
    required this.sellQty,
    required this.netQty,
    required this.avgEntryPrice,
    required this.totalMargin,
    this.ltp,
    this.unrealisedPnl,
  });

  factory PositionData.fromJson(Map<String, dynamic> json) => PositionData(
    contractName: json['contract_name'] as String,
    exchangeToken: json['exchange_token'] as String,
    buyQty: (json['buy_qty'] as num).toInt(),
    sellQty: (json['sell_qty'] as num).toInt(),
    netQty: (json['net_qty'] as num).toInt(),
    avgEntryPrice: (json['avg_entry_price'] as num).toDouble(),
    totalMargin: (json['total_margin'] as num).toDouble(),
    ltp: json['ltp'] != null ? (json['ltp'] as num).toDouble() : null,
    unrealisedPnl: json['unrealised_pnl'] != null
        ? (json['unrealised_pnl'] as num).toDouble()
        : null,
  );

  // FIX: Only compute P&L when avgEntryPrice > 0 (i.e. order is actually filled)
  PositionData copyWithLtp(double ltp) {
    final bool isFilled = avgEntryPrice > 0;

    final pnl = isFilled
        ? (netQty > 0
              ? (ltp - avgEntryPrice) * netQty.abs()
              : (avgEntryPrice - ltp) * netQty.abs())
        : null;

    return PositionData(
      contractName: contractName,
      exchangeToken: exchangeToken,
      buyQty: buyQty,
      sellQty: sellQty,
      netQty: netQty,
      avgEntryPrice: avgEntryPrice,
      totalMargin: totalMargin,
      ltp: ltp,
      unrealisedPnl: pnl,
    );
  }
}

class BookedPositionData {
  final String orderId;
  final String contractName;
  final int qty;
  final String side;
  final double entryPrice;
  final double exitPrice;
  final double realisedPnl;
  final DateTime closedAt;

  const BookedPositionData({
    required this.orderId,
    required this.contractName,
    required this.qty,
    required this.side,
    required this.entryPrice,
    required this.exitPrice,
    required this.realisedPnl,
    required this.closedAt,
  });

  factory BookedPositionData.fromJson(Map<String, dynamic> json) {
    return BookedPositionData(
      orderId: json['order_id'] as String,
      contractName: json['contract_name'] as String,
      qty: (json['qty'] as num).toInt(),
      side: json['side'] as String,
      entryPrice: (json['entry_price'] as num).toDouble(),
      exitPrice: (json['exit_price'] as num).toDouble(),
      realisedPnl: (json['realised_pnl'] as num).toDouble(),
      closedAt: DateTime.parse(json['closed_at'] as String),
    );
  }
}

class MarginPageData {
  final WalletData wallet;
  final List<PositionData> positions;
  final List<BookedPositionData> bookedPositions;

  const MarginPageData({
    required this.wallet,
    required this.positions,
    required this.bookedPositions,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

final walletProvider = FutureProvider.family<WalletData, String>((
  ref,
  userId,
) async {
  final uri = Uri.parse('http://69.62.75.117:8000/auth/wallet/$userId');

  final response = await http.get(uri);

  debugPrint('Wallet API response: ${response.statusCode} - ${response.body}');

  if (response.statusCode == 200) {
    return WalletData.fromJson(jsonDecode(response.body));
  }

  if (response.statusCode == 404) {
    return const WalletData(
      balance: 0,
      marginUsed: 0,
      available: 0,
      realisedPnl: 0,
    );
  }

  throw Exception('Wallet error ${response.statusCode}: ${response.body}');
});

final positionsProvider = FutureProvider.family<List<PositionData>, String>((
  ref,
  userId,
) async {
  final uri = Uri.parse('http://69.62.75.117:8765/positions/$userId');

  final response = await http.get(uri);

  if (response.statusCode == 200) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    final list = body['positions'] as List<dynamic>;

    return list
        .map((e) => PositionData.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  if (response.statusCode == 404) return [];

  throw Exception('Positions error ${response.statusCode}: ${response.body}');
});

final bookedPositionsProvider =
    FutureProvider.family<List<BookedPositionData>, String>((
      ref,
      userId,
    ) async {
      final uri = Uri.parse('http://69.62.75.117:8765/booked-pnl/$userId');

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;

        final list = body['trades'] as List<dynamic>;

        return list
            .map((e) => BookedPositionData.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      if (response.statusCode == 404) return [];

      throw Exception(
        'Booked positions error ${response.statusCode}: ${response.body}',
      );
    });

final marginPageProvider = FutureProvider.family<MarginPageData, String>((
  ref,
  userId,
) async {
  final wallet = await ref.watch(walletProvider(userId).future);

  final positions = await ref.watch(positionsProvider(userId).future);

  final bookedPositions = await ref.watch(
    bookedPositionsProvider(userId).future,
  );

  return MarginPageData(
    wallet: wallet,
    positions: positions,
    bookedPositions: bookedPositions,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class MarginScreen extends ConsumerStatefulWidget {
  const MarginScreen({super.key});

  @override
  ConsumerState<MarginScreen> createState() => _MarginScreenState();
}

class _MarginScreenState extends ConsumerState<MarginScreen> {
  WebSocketChannel? _channel;
  Timer? _pingTimer;

  final Map<String, double> _ltpMap = {};

  String get _userId => ref.read(authProvider.notifier).userId ?? 'unknown';

  @override
  void initState() {
    super.initState();

    Future.microtask(() {
      if (!mounted) return;

      ref.invalidate(walletProvider(_userId));
      ref.invalidate(positionsProvider(_userId));
      ref.invalidate(bookedPositionsProvider(_userId));
      ref.invalidate(marginPageProvider(_userId));

      _connectWs();
    });
  }

  void _connectWs() {
    final userId = _userId;

    final uri = Uri.parse('ws://69.62.75.117:8765/ws/pnl/$userId');

    _channel?.sink.close();

    _channel = WebSocketChannel.connect(uri);

    _channel!.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String) as Map<String, dynamic>;

          final orders = data['orders'] as List<dynamic>? ?? [];

          final updates = <String, double>{};

          for (final o in orders) {
            final order = o as Map<String, dynamic>;

            final token = order['exchange_token'] as String? ?? '';

            final ltp = order['ltp'];

            if (token.isNotEmpty && ltp != null) {
              updates[token] = (ltp as num).toDouble();
            }
          }

          if (updates.isNotEmpty && mounted) {
            setState(() {
              _ltpMap.addAll(updates);
            });
          }
        } catch (_) {}
      },
      onError: (_) => _scheduleReconnect(),
      onDone: () => _scheduleReconnect(),
    );

    _pingTimer?.cancel();

    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        _channel?.sink.add('ping');
      } catch (_) {}
    });
  }

  void _scheduleReconnect() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _connectWs();
      }
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _channel?.sink.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = _userId;

    final asyncData = ref.watch(marginPageProvider(userId));

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark ? const Color(0xFF121212) : Colors.white,
      child: asyncData.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),

              const SizedBox(height: 12),

              Text(
                'Failed to load margin data',
                style: TextStyle(
                  color: isDark ? Colors.white70 : Colors.black54,
                  fontSize: 15,
                ),
              ),

              const SizedBox(height: 8),

              TextButton(
                onPressed: () {
                  ref.invalidate(walletProvider(userId));
                  ref.invalidate(positionsProvider(userId));
                  ref.invalidate(bookedPositionsProvider(userId));
                  ref.invalidate(marginPageProvider(userId));
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (data) {
          final livePositions = data.positions.map((p) {
            final ltp = _ltpMap[p.exchangeToken];

            return ltp != null && ltp > 0 ? p.copyWithLtp(ltp) : p;
          }).toList();

          return _MarginContent(
            wallet: data.wallet,
            positions: livePositions,
            bookedPositions: data.bookedPositions,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content
// ─────────────────────────────────────────────────────────────────────────────

class _MarginContent extends StatelessWidget {
  final WalletData wallet;
  final List<PositionData> positions;
  final List<BookedPositionData> bookedPositions;

  const _MarginContent({
    required this.wallet,
    required this.positions,
    required this.bookedPositions,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    final borderColor = isDark ? Colors.white10 : const Color(0xFFE5E5E7);

    final headerColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : const Color(0xFFF4F4F5);

    final totalMarginCap = wallet.marginUsed + wallet.available;

    final utilization = totalMarginCap > 0
        ? wallet.marginUsed / totalMarginCap
        : 0.0;

    // FIX: Only sum P&L from filled positions (avgEntryPrice > 0)
    final totalUnrealisedPnl = positions
        .where((p) => p.avgEntryPrice > 0)
        .fold<double>(0, (sum, p) => sum + (p.unrealisedPnl ?? 0));

    // Only show unrealised P&L row if there are filled positions
    final hasFilledPositions = positions.any((p) => p.avgEntryPrice > 0);

    final totalBookedPnl = bookedPositions.fold<double>(
      0,
      (sum, p) => sum + p.realisedPnl,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─────────────────────────────────────────
          // Margin Summary Card
          // ─────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MarginRow(
                  label: 'Available Margin',
                  value: '₹${_fmt(wallet.available)}',
                ),

                const SizedBox(height: 12),

                _MarginRow(
                  label: 'Used Margin',
                  value: '₹${_fmt(wallet.marginUsed)}',
                ),

                const SizedBox(height: 12),

                _MarginRow(
                  label: 'Total Margin',
                  value: '₹${_fmt(totalMarginCap)}',
                ),

                // FIX: Only show unrealised P&L row when there are filled positions
                if (hasFilledPositions) ...[
                  const SizedBox(height: 12),

                  _MarginRow(
                    label: 'Unrealised P&L',
                    value:
                        '${totalUnrealisedPnl >= 0 ? '+' : ''}₹${_fmt(totalUnrealisedPnl)}',
                    valueColor: totalUnrealisedPnl >= 0
                        ? const Color(0xFF81C784)
                        : const Color(0xFFE57373),
                  ),
                ],

                if (bookedPositions.isNotEmpty) ...[
                  const SizedBox(height: 12),

                  _MarginRow(
                    label: 'Booked P&L',
                    value:
                        '${totalBookedPnl >= 0 ? '+' : ''}₹${_fmt(totalBookedPnl)}',
                    valueColor: totalBookedPnl >= 0
                        ? const Color(0xFF81C784)
                        : const Color(0xFFE57373),
                  ),
                ],

                const SizedBox(height: 20),

                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: utilization.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: isDark
                        ? Colors.white10
                        : const Color(0xFFE5E5E7),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark
                          ? const Color(0xFF81C784)
                          : const Color(0xFF2E7D32),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Margin Utilization',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.grey.shade400 : Colors.black,
                        fontWeight: FontWeight.w400,
                      ),
                    ),

                    Text(
                      '${(utilization * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 15,
                        color: isDark
                            ? const Color(0xFF81C784)
                            : const Color(0xFF2E7D32),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ─────────────────────────────────────────
          // OPEN POSITIONS TABLE
          // ─────────────────────────────────────────
          _TableContainer(
            title: 'Positions',
            borderColor: borderColor,
            cardColor: cardColor,
            headerColor: headerColor,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      _PosHeaderCell(label: 'Symbol', flex: 3),

                      _PosHeaderCell(label: 'Qty', flex: 2),

                      _PosHeaderCell(label: 'Avg. Price', flex: 3),

                      _PosHeaderCell(
                        label: 'LTP',
                        flex: 2,
                        align: TextAlign.center,
                      ),

                      _PosHeaderCell(
                        label: 'P&L',
                        flex: 3,
                        align: TextAlign.right,
                      ),
                    ],
                  ),
                ),

                Divider(height: 1, thickness: 1, color: borderColor),

                if (positions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'No open positions',
                        style: TextStyle(
                          color: isDark
                              ? Colors.grey.shade500
                              : Colors.grey.shade400,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: positions.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, thickness: 1, color: borderColor),
                    itemBuilder: (context, index) =>
                        _PositionRow(position: positions[index]),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ─────────────────────────────────────────
          // BOOKED POSITIONS TABLE
          // ─────────────────────────────────────────
          _TableContainer(
            title: 'Booked Positions',
            borderColor: borderColor,
            cardColor: cardColor,
            headerColor: headerColor,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      _PosHeaderCell(label: 'Symbol', flex: 3),

                      _PosHeaderCell(label: 'Qty', flex: 2),

                      _PosHeaderCell(label: 'Entry', flex: 3),

                      _PosHeaderCell(label: 'Exit', flex: 3),

                      _PosHeaderCell(
                        label: 'Booked P&L',
                        flex: 3,
                        align: TextAlign.right,
                      ),
                    ],
                  ),
                ),

                Divider(height: 1, thickness: 1, color: borderColor),

                if (bookedPositions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'No booked positions today',
                        style: TextStyle(
                          color: isDark
                              ? Colors.grey.shade500
                              : Colors.grey.shade400,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: bookedPositions.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, thickness: 1, color: borderColor),
                    itemBuilder: (context, index) {
                      final trade = bookedPositions[index];

                      return _BookedPositionRow(trade: trade);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double value) {
    return value
        .toStringAsFixed(0)
        .replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Table Container
// ─────────────────────────────────────────────────────────────────────────────

class _TableContainer extends StatelessWidget {
  final String title;
  final Widget child;
  final Color borderColor;
  final Color cardColor;
  final Color headerColor;

  const _TableContainer({
    required this.title,
    required this.child,
    required this.borderColor,
    required this.cardColor,
    required this.headerColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(12),
          color: cardColor,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              color: headerColor,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),

            Divider(height: 1, thickness: 1, color: borderColor),

            child,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub Widgets
// ─────────────────────────────────────────────────────────────────────────────

class _MarginRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MarginRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.grey.shade400 : Colors.black,
            fontWeight: FontWeight.w400,
          ),
        ),

        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            color: valueColor ?? (isDark ? Colors.white : Colors.black),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PosHeaderCell extends StatelessWidget {
  final String label;
  final int flex;
  final TextAlign align;

  const _PosHeaderCell({
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
          color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  final PositionData position;

  const _PositionRow({required this.position});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // FIX: Don't show P&L if the position is not yet filled (avgEntryPrice == 0)
    final bool isFilled = position.avgEntryPrice > 0;
    final pnl = isFilled ? position.unrealisedPnl : null;
    final isProfit = (pnl ?? 0) >= 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  position.contractName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),

                Text(
                  position.exchangeToken,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          Expanded(
            flex: 2,
            child: Text(
              '${position.netQty}',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade300 : Colors.black,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          Expanded(
            flex: 3,
            child: Text(
              isFilled ? '₹${position.avgEntryPrice.toStringAsFixed(2)}' : '—',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade300 : Colors.black,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Text(
              position.ltp != null && position.ltp! > 0
                  ? '₹${position.ltp!.toStringAsFixed(2)}'
                  : '—',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),

          Expanded(
            flex: 3,
            child: Text(
              pnl != null
                  ? '${isProfit ? '+' : ''}₹${pnl.toStringAsFixed(2)}'
                  : '—',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: pnl == null
                    ? (isDark ? Colors.grey.shade500 : Colors.grey.shade400)
                    : (isProfit
                          ? const Color(0xFF81C784)
                          : const Color(0xFFE57373)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookedPositionRow extends StatelessWidget {
  final BookedPositionData trade;

  const _BookedPositionRow({required this.trade});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isProfit = trade.realisedPnl >= 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              trade.contractName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Text(
              '${trade.qty}',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade300 : Colors.black,
              ),
            ),
          ),

          Expanded(
            flex: 3,
            child: Text(
              '₹${trade.entryPrice.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade300 : Colors.black,
              ),
            ),
          ),

          Expanded(
            flex: 3,
            child: Text(
              '₹${trade.exitPrice.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade300 : Colors.black,
              ),
            ),
          ),

          Expanded(
            flex: 3,
            child: Text(
              '${isProfit ? '+' : ''}₹${trade.realisedPnl.toStringAsFixed(2)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isProfit
                    ? const Color(0xFF81C784)
                    : const Color(0xFFE57373),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
