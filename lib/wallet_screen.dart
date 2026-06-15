import 'dart:convert';
import 'package:capit_n_bulls/providers/auth_provider.dart';
import 'package:capit_n_bulls/trade_book_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

// ─── Models ────────────────────────────────────────────────────────────────

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

enum TxType { credit, debit }

/// Transaction category — drives the detail sheet layout.
enum TxCategory { order, pnlSettlement, marginAdjustment }

class TransactionData {
  final String id;
  final String title;
  final double amount;
  final TxType type;
  final DateTime date;
  final TxCategory category;

  // Order-specific (null for non-order transactions)
  final String? symbol;
  final String? side; // 'BUY' | 'SELL'
  final int? qty;
  final String? productType; // 'MIS' | 'NRML'
  final String? orderType; // 'MARKET' | 'LIMIT'
  final double? pricePerUnit;
  final String? status; // 'EXECUTED' | 'PENDING' | 'REJECTED'
  final String? leg; // 'ENTRY' | 'EXIT'

  // Entry / exit prices
  final double? entryPrice;
  final double? exitPrice;

  // P&L settlement
  final double? realisedPnl;

  const TransactionData({
    required this.id,
    required this.title,
    required this.amount,
    required this.type,
    required this.date,
    required this.category,
    this.symbol,
    this.side,
    this.qty,
    this.productType,
    this.orderType,
    this.pricePerUnit,
    this.status,
    this.leg,
    this.entryPrice,
    this.exitPrice,
    this.realisedPnl,
  });

  factory TransactionData.fromJson(Map<String, dynamic> json) =>
      TransactionData(
        id: json['id'] as String,
        title: json['title'] as String,
        amount: (json['amount'] as num).toDouble(),
        type: json['type'] == 'credit' ? TxType.credit : TxType.debit,
        date: DateTime.parse(json['date'] as String),
        category: _parseCategory(json['category'] as String),
        symbol: json['symbol'] as String?,
        side: json['side'] as String?,
        qty: json['qty'] != null ? (json['qty'] as num).toInt() : null,
        productType: json['product_type'] as String?,
        orderType: json['order_type'] as String?,
        pricePerUnit: json['price_per_unit'] != null
            ? (json['price_per_unit'] as num).toDouble()
            : null,
        status: json['status'] as String?,
        leg: json['leg'] as String?,
        entryPrice: json['entry_price'] != null
            ? (json['entry_price'] as num).toDouble()
            : null,
        exitPrice: json['exit_price'] != null
            ? (json['exit_price'] as num).toDouble()
            : null,
        realisedPnl: json['realised_pnl'] != null
            ? (json['realised_pnl'] as num).toDouble()
            : null,
      );

  static TxCategory _parseCategory(String s) {
    switch (s) {
      case 'pnl_settlement':
        return TxCategory.pnlSettlement;
      case 'margin_adjustment':
        return TxCategory.marginAdjustment;
      default:
        return TxCategory.order;
    }
  }
}

// ─── Converter ─────────────────────────────────────────────────────────────

/// Converts a TradeBookEntry to a TransactionData for display in wallet.
TransactionData _tradeToTransaction(TradeBookEntry trade) {
  final totalValue = trade.tradePrice * trade.quantity;
  final isCredit = trade.action.toLowerCase() == 'sell';

  // Set entry/exit prices based on leg type
  final entryPrice = trade.leg.toUpperCase() == 'ENTRY'
      ? trade.tradePrice
      : null;
  final exitPrice = trade.leg.toUpperCase() == 'EXIT' ? trade.tradePrice : null;

  return TransactionData(
    id: trade.symbolCode,
    title: '${trade.action.toUpperCase()} ${trade.symbolName}',
    amount: totalValue,
    type: isCredit ? TxType.credit : TxType.debit,
    date: trade.tradeDateTime,
    category: TxCategory.order,
    symbol: trade.symbolName,
    side: trade.action.toUpperCase(),
    qty: trade.quantity,
    productType: null,
    orderType: null,
    pricePerUnit: trade.tradePrice,
    status: 'EXECUTED',
    leg: trade.leg,
    entryPrice: entryPrice,
    exitPrice: exitPrice,
    realisedPnl: trade.pnl,
  );
}

// ─── Providers ─────────────────────────────────────────────────────────────

final walletProvider = FutureProvider.family<WalletData, String>((
  ref,
  userId,
) async {
  final uri = Uri.parse('http://69.62.75.117:8000/auth/wallet/$userId');
  final response = await http.get(uri);

  debugPrint(
    'Wallet API response: ${response.statusCode} ${response.body} for userId: $userId',
  );

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
  throw Exception('Wallet error ${response.statusCode}');
});

/// Transactions provider — fetches data from the tradebook API.
final transactionsProvider =
    FutureProvider.family<List<TransactionData>, String>((ref, userId) async {
      try {
        final trades = await TradebookApi.fetchTrades(userId);
        final transactions = trades.map(_tradeToTransaction).toList();

        // Sort by date (newest first)
        transactions.sort((a, b) => b.date.compareTo(a.date));

        return transactions;
      } catch (e) {
        debugPrint('Failed to fetch transactions: $e');
        rethrow;
      }
    });

// ─── Screen ────────────────────────────────────────────────────────────────

class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  String _userId(WidgetRef ref) =>
      ref.read(authProvider.notifier).userId ?? 'unknown';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF121212) : Colors.white;
    final dividerColor = isDark ? Colors.white10 : Colors.grey.shade200;

    final userId = _userId(ref);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDark ? Colors.white : Colors.black,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Transactions & Wallet',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: dividerColor),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(walletProvider(userId));
          ref.invalidate(transactionsProvider(userId));
        },
        child: _WalletBody(userId: userId),
      ),
    );
  }
}

// ─── Body ──────────────────────────────────────────────────────────────────

class _WalletBody extends ConsumerWidget {
  final String userId;
  const _WalletBody({required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final walletAsync = ref.watch(walletProvider(userId));
    final txAsync = ref.watch(transactionsProvider(userId));

    return CustomScrollView(
      slivers: [
        // ── Wallet card ────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: walletAsync.when(
              loading: () => _WalletCardSkeleton(isDark: isDark),
              error: (e, _) => _ErrorCard(
                message: 'Could not load wallet',
                onRetry: () => ref.invalidate(walletProvider(userId)),
                isDark: isDark,
              ),
              data: (wallet) => _WalletCard(wallet: wallet, isDark: isDark),
            ),
          ),
        ),

        // ── Section header ─────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 10),
            child: Text(
              'Recent Transactions',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ),

        // ── Transactions ───────────────────────────────────────────────
        txAsync.when(
          loading: () => SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _TxSkeleton(isDark: isDark),
              childCount: 5,
            ),
          ),
          error: (e, _) => SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _ErrorCard(
                message: 'Could not load transactions',
                onRetry: () => ref.invalidate(transactionsProvider(userId)),
                isDark: isDark,
              ),
            ),
          ),
          data: (transactions) {
            if (transactions.isEmpty) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No transactions yet',
                    style: TextStyle(
                      color: isDark
                          ? Colors.grey.shade600
                          : Colors.grey.shade400,
                      fontSize: 14,
                    ),
                  ),
                ),
              );
            }

            return SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final tx = transactions[index];
                final isLast = index == transactions.length - 1;
                return _TransactionTile(tx: tx, isDark: isDark, isLast: isLast);
              }, childCount: transactions.length),
            );
          },
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

// ─── Wallet Card ───────────────────────────────────────────────────────────

class _WalletCard extends StatelessWidget {
  final WalletData wallet;
  final bool isDark;

  const _WalletCard({required this.wallet, required this.isDark});

  String _fmt(double v) => v
      .toStringAsFixed(0)
      .replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]},',
      );

  @override
  Widget build(BuildContext context) {
    final cardColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final borderColor = isDark ? Colors.white10 : const Color(0xFFE5E5E7);
    final totalMargin = wallet.marginUsed + wallet.available;
    final utilization = totalMargin > 0 ? wallet.marginUsed / totalMargin : 0.0;

    final pnlPositive = wallet.realisedPnl >= 0;
    final pnlColor = pnlPositive
        ? (isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32))
        : (isDark ? const Color(0xFFE57373) : const Color(0xFFC62828));

    return Container(
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
          Text(
            'Total Balance',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '₹${_fmt(wallet.balance)}',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.black,
              letterSpacing: -0.5,
            ),
          ),

          const SizedBox(height: 20),
          Divider(color: borderColor, height: 1),
          const SizedBox(height: 16),

          _MarginRow(
            label: 'Available Margin',
            value: '₹${_fmt(wallet.available)}',
            isDark: isDark,
          ),
          const SizedBox(height: 12),
          _MarginRow(
            label: 'Used Margin',
            value: '₹${_fmt(wallet.marginUsed)}',
            isDark: isDark,
          ),
          const SizedBox(height: 12),
          _MarginRow(
            label: 'Realised P&L',
            value: '${pnlPositive ? '+' : ''}₹${_fmt(wallet.realisedPnl)}',
            valueColor: pnlColor,
            isDark: isDark,
          ),

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
                isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Margin Utilization',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.black54,
                ),
              ),
              Text(
                '${(utilization * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? const Color(0xFF81C784)
                      : const Color(0xFF2E7D32),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Transaction Tile ───────────────────────────────────────────────────────

class _TransactionTile extends StatelessWidget {
  final TransactionData tx;
  final bool isDark;
  final bool isLast;

  const _TransactionTile({
    required this.tx,
    required this.isDark,
    required this.isLast,
  });

  static const _gainColor = Color(0xFF3FD47E);
  static const _lossColor = Color(0xFFE05252);

  String _formatDate(DateTime d) {
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
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '${d.day} ${months[d.month - 1]} · $h:$m $ampm';
  }

  String _contextLine() {
    switch (tx.category) {
      case TxCategory.order:
        final parts = <String>[];
        if (tx.qty != null) parts.add('${tx.qty} qty');
        if (tx.leg != null) parts.add(tx.leg!);
        if (tx.productType != null) parts.add(tx.productType!);
        if (tx.orderType != null) parts.add(tx.orderType!);
        return parts.join(' · ');
      case TxCategory.pnlSettlement:
        return 'End of Day Settlement';
      case TxCategory.marginAdjustment:
        return 'Margin Adjustment';
    }
  }

  /// Entry/exit price summary line shown in the tile.
  String? _priceLine() {
    if (tx.category != TxCategory.order) return null;
    if (tx.entryPrice == null && tx.exitPrice == null) return null;

    final parts = <String>[];
    if (tx.entryPrice != null) {
      parts.add('Entry ₹${tx.entryPrice!.toStringAsFixed(2)}');
    }
    if (tx.exitPrice != null) {
      parts.add('Exit ₹${tx.exitPrice!.toStringAsFixed(2)}');
    }
    return parts.join('  →  ');
  }

  IconData _icon() {
    switch (tx.category) {
      case TxCategory.order:
        return tx.type == TxType.debit
            ? Icons.arrow_upward_rounded
            : Icons.arrow_downward_rounded;
      case TxCategory.pnlSettlement:
        return Icons.account_balance_wallet_outlined;
      case TxCategory.marginAdjustment:
        return Icons.tune_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCredit = tx.type == TxType.credit;
    final amountColor = isCredit ? _gainColor : _lossColor;
    final iconBg = isCredit
        ? _gainColor.withValues(alpha: 0.12)
        : _lossColor.withValues(alpha: 0.12);
    final dividerColor = isDark ? Colors.white10 : Colors.grey.shade200;
    final contextLine = _contextLine();
    final priceLine = _priceLine();

    return Column(
      children: [
        InkWell(
          onTap: () => _TxDetailSheet.show(context, tx, isDark),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_icon(), color: amountColor, size: 18),
                ),
                const SizedBox(width: 12),

                // Title + context + price line
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tx.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      if (contextLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          contextLine,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.grey.shade600
                                : Colors.grey.shade500,
                          ),
                        ),
                      ],
                      if (priceLine != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          priceLine,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? Colors.grey.shade500
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // Amount + date
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${isCredit ? '+' : '-'}₹${tx.amount.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: amountColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDate(tx.date),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? Colors.grey.shade600
                            : Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!isLast)
          Divider(height: 1, thickness: 1, indent: 68, color: dividerColor),
      ],
    );
  }
}

// ─── Transaction Detail Bottom Sheet ───────────────────────────────────────

class _TxDetailSheet extends StatelessWidget {
  final TransactionData tx;
  final bool isDark;

  const _TxDetailSheet({required this.tx, required this.isDark});

  static void show(BuildContext context, TransactionData tx, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TxDetailSheet(tx: tx, isDark: isDark),
    );
  }

  static const _gainColor = Color(0xFF3FD47E);
  static const _lossColor = Color(0xFFE05252);

  String _formatFullDate(DateTime d) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '${d.day} ${months[d.month - 1]} ${d.year}, $h:$m:$s $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final isCredit = tx.type == TxType.credit;
    final accentColor = isCredit ? _gainColor : _lossColor;
    final surfaceColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final borderColor = isDark ? Colors.white10 : const Color(0xFFE5E5E7);
    final labelColor = isDark ? Colors.grey.shade500 : Colors.grey.shade600;
    final valueColor = isDark ? Colors.white : Colors.black;

    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header — amount + title
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isCredit
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  color: accentColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatFullDate(tx.date),
                      style: TextStyle(fontSize: 12, color: labelColor),
                    ),
                  ],
                ),
              ),
              Text(
                '${isCredit ? '+' : '-'}₹${tx.amount.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: accentColor,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          Divider(color: borderColor, height: 1),
          const SizedBox(height: 20),

          // Detail rows — varies by category
          ..._buildRows(labelColor, valueColor, borderColor, accentColor),

          const SizedBox(height: 20),

          // Status chip
          if (tx.status != null)
            _StatusChip(status: tx.status!, isDark: isDark),
        ],
      ),
    );
  }

  List<Widget> _buildRows(
    Color labelColor,
    Color valueColor,
    Color borderColor,
    Color accentColor,
  ) {
    switch (tx.category) {
      case TxCategory.order:
        return [
          _DetailRow(
            label: 'Transaction ID',
            value: tx.id.toUpperCase(),
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Symbol',
            value: tx.symbol ?? '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Leg',
            value: tx.leg ?? '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Side',
            value: tx.side ?? '—',
            labelColor: labelColor,
            valueColor: accentColor,
            valueBold: true,
          ),
          _DetailRow(
            label: 'Quantity',
            value: tx.qty?.toString() ?? '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          // ── Entry / Exit price block ──────────────────────────────
          if (tx.entryPrice != null || tx.exitPrice != null)
            _PriceRow(
              entryPrice: tx.entryPrice,
              exitPrice: tx.exitPrice,
              isDark: isDark,
              labelColor: labelColor,
              valueColor: valueColor,
            ),
          _DetailRow(
            label: 'Trade Price',
            value: tx.pricePerUnit != null
                ? '₹${tx.pricePerUnit!.toStringAsFixed(2)}'
                : '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Order Type',
            value: tx.orderType ?? '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Product',
            value: tx.productType ?? '—',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Margin Impact',
            value:
                '${tx.type == TxType.debit ? '-' : '+'}₹${tx.amount.toStringAsFixed(2)}',
            labelColor: labelColor,
            valueColor: accentColor,
            valueBold: true,
          ),
          if (tx.realisedPnl != null)
            _DetailRow(
              label: 'Realised P&L',
              value:
                  '${tx.realisedPnl! >= 0 ? '+' : ''}₹${tx.realisedPnl!.toStringAsFixed(2)}',
              labelColor: labelColor,
              valueColor: tx.realisedPnl! >= 0
                  ? const Color(0xFF3FD47E)
                  : const Color(0xFFE05252),
              valueBold: true,
            ),
        ];

      case TxCategory.pnlSettlement:
        return [
          _DetailRow(
            label: 'Transaction ID',
            value: tx.id.toUpperCase(),
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Type',
            value: 'End of Day P&L Settlement',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Realised P&L',
            value: tx.realisedPnl != null
                ? '${tx.realisedPnl! >= 0 ? '+' : ''}₹${tx.realisedPnl!.toStringAsFixed(2)}'
                : '—',
            labelColor: labelColor,
            valueColor: accentColor,
            valueBold: true,
          ),
          _DetailRow(
            label: 'Credited to Balance',
            value: '+₹${tx.amount.toStringAsFixed(2)}',
            labelColor: labelColor,
            valueColor: accentColor,
            valueBold: true,
          ),
        ];

      case TxCategory.marginAdjustment:
        return [
          _DetailRow(
            label: 'Transaction ID',
            value: tx.id.toUpperCase(),
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Type',
            value: 'Margin Adjustment',
            labelColor: labelColor,
            valueColor: valueColor,
          ),
          _DetailRow(
            label: 'Margin Impact',
            value:
                '${tx.type == TxType.debit ? '-' : '+'}₹${tx.amount.toStringAsFixed(2)}',
            labelColor: labelColor,
            valueColor: accentColor,
            valueBold: true,
          ),
        ];
    }
  }
}

// ─── Entry / Exit Price Row ─────────────────────────────────────────────────

/// A compact two-cell price display used in the detail sheet.
class _PriceRow extends StatelessWidget {
  final double? entryPrice;
  final double? exitPrice;
  final bool isDark;
  final Color labelColor;
  final Color valueColor;

  const _PriceRow({
    required this.entryPrice,
    required this.exitPrice,
    required this.isDark,
    required this.labelColor,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F7);
    final borderColor = isDark ? Colors.white10 : const Color(0xFFE5E5E7);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Entry
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Entry Price',
                    style: TextStyle(fontSize: 11, color: labelColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entryPrice != null
                        ? '₹${entryPrice!.toStringAsFixed(2)}'
                        : '—',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: valueColor,
                    ),
                  ),
                ],
              ),
            ),

            // Arrow divider
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: labelColor,
              ),
            ),

            // Exit
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Exit Price',
                    style: TextStyle(fontSize: 11, color: labelColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    exitPrice != null
                        ? '₹${exitPrice!.toStringAsFixed(2)}'
                        : '—',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: exitPrice != null && entryPrice != null
                          ? (exitPrice! >= entryPrice!
                                ? const Color(0xFF3FD47E)
                                : const Color(0xFFE05252))
                          : valueColor,
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

// ─── Detail Row ─────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color labelColor;
  final Color valueColor;
  final bool valueBold;

  const _DetailRow({
    required this.label,
    required this.value,
    required this.labelColor,
    required this.valueColor,
    this.valueBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: labelColor),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                color: valueColor,
                fontWeight: valueBold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final bool isDark;

  const _StatusChip({required this.status, required this.isDark});

  @override
  Widget build(BuildContext context) {
    Color chipColor;
    switch (status.toUpperCase()) {
      case 'EXECUTED':
        chipColor = const Color(0xFF3FD47E);
        break;
      case 'PENDING':
        chipColor = const Color(0xFFFFA726);
        break;
      case 'REJECTED':
        chipColor = const Color(0xFFE05252);
        break;
      default:
        chipColor = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: chipColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: chipColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            status.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: chipColor,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Skeleton / Error helpers ───────────────────────────────────────────────

class _WalletCardSkeleton extends StatelessWidget {
  final bool isDark;
  const _WalletCardSkeleton({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final shimmer = isDark ? Colors.white10 : Colors.grey.shade200;
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: shimmer,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

class _TxSkeleton extends StatelessWidget {
  final bool isDark;
  const _TxSkeleton({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final shimmer = isDark ? Colors.white10 : Colors.grey.shade200;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: shimmer, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 12,
                  width: 120,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 80,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 14,
            width: 70,
            decoration: BoxDecoration(
              color: shimmer,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final bool isDark;

  const _ErrorCard({
    required this.message,
    required this.onRetry,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

// ─── Shared margin row ──────────────────────────────────────────────────────

class _MarginRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool isDark;

  const _MarginRow({
    required this.label,
    required this.value,
    required this.isDark,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.grey.shade400 : Colors.black54,
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
