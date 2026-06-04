import 'dart:async';
import 'dart:convert';
import 'package:capit_n_bulls/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

enum OrderStatus { open, pending, closed, cancelled }

// ─── Contract name to numeric token mapping ───────────────────────────────────

class ContractTokenRegistry {
  static final Map<String, int> _contractToToken = {};

  static void registerContract(String contractName, int instrumentToken) {
    _contractToToken[contractName] = instrumentToken;
  }

  static int? getToken(String contractName) => _contractToToken[contractName];

  static int? getTokenFuzzy(String contractName) {
    final exact = _contractToToken[contractName];
    if (exact != null) return exact;
    for (final entry in _contractToToken.entries) {
      if (entry.key.startsWith(contractName) ||
          contractName.startsWith(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  static void clear() => _contractToToken.clear();

  static Map<String, int> get all => Map.unmodifiable(_contractToToken);
}

// ─── Order Model ──────────────────────────────────────────────────────────────

class Order {
  final String orderId;
  final String time;
  final String symbol;
  final String contractName;
  final String exchangeToken;
  final String instrumentToken;
  final String action;
  final int quantity;
  final double price;
  final double totalValue;
  final OrderStatus status;
  final double currentPrice;

  const Order({
    required this.orderId,
    required this.time,
    required this.symbol,
    required this.contractName,
    required this.exchangeToken,
    required this.instrumentToken,
    required this.action,
    required this.quantity,
    required this.price,
    required this.totalValue,
    required this.status,
    required this.currentPrice,
  });

  Order copyWithLtp(double ltp) => Order(
    orderId: orderId,
    time: time,
    symbol: symbol,
    contractName: contractName,
    exchangeToken: exchangeToken,
    instrumentToken: instrumentToken,
    action: action,
    quantity: quantity,
    price: price,
    totalValue: totalValue,
    status: status,
    currentPrice: ltp,
  );

  String get bestToken {
    if (contractName.isNotEmpty && contractName != 'UNKNOWN') {
      return contractName;
    }
    final it = int.tryParse(instrumentToken) ?? 0;
    if (it > 0) return instrumentToken;
    final et = int.tryParse(exchangeToken) ?? 0;
    if (et > 0) return exchangeToken;
    return contractName;
  }

  factory Order.fromJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] as String? ?? '').toUpperCase();
    final status = switch (rawStatus) {
      'OPEN' => OrderStatus.open,
      'PENDING' => OrderStatus.pending,
      'CLOSED' => OrderStatus.closed,
      'CANCELLED' || 'CANCELED' => OrderStatus.cancelled,
      _ => OrderStatus.open,
    };

    final contractName = json['contract_name'] as String? ?? 'UNKNOWN';
    final instrumentTokenInt = (json['instrument_token'] as num?)?.toInt() ?? 0;

    String exchangeToken;
    if (instrumentTokenInt > 0) {
      exchangeToken = instrumentTokenInt.toString();
    } else {
      final registered = ContractTokenRegistry.getTokenFuzzy(contractName);
      if (registered != null) {
        exchangeToken = registered.toString();
      } else {
        final raw = json['exchange_token'];
        exchangeToken = raw is num ? raw.toString() : 'UNKNOWN';
      }
    }

    final symbol = _parseSymbol(contractName);

    final createdAt =
        DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
        DateTime.now();
    final time =
        '${createdAt.hour}.${createdAt.minute.toString().padLeft(2, '0')}';

    final side = json['side'] as String? ?? 'BUY';
    final action = side[0].toUpperCase() + side.substring(1).toLowerCase();

    final entryPrice = (json['entry_price'] as num?)?.toDouble() ?? 0.0;
    final qty = (json['qty'] as num?)?.toInt() ?? 1;

    return Order(
      orderId: json['order_id'] as String? ?? '',
      time: time,
      symbol: symbol,
      contractName: contractName,
      exchangeToken: exchangeToken,
      instrumentToken: instrumentTokenInt.toString(),
      action: action,
      quantity: qty,
      price: entryPrice,
      totalValue: entryPrice * qty,
      status: status,
      currentPrice: entryPrice,
    );
  }

  static String _parseSymbol(String contractName) {
    var s = contractName.replaceAll(RegExp(r'(FUT|CE|PE)$'), '');
    s = s.replaceAll(RegExp(r'\d{2}[A-Z]{3}$'), '');
    return s.isEmpty ? contractName : s;
  }
}

// ─── Limit Order Model ────────────────────────────────────────────────────────
// Sourced from GET /positions/:userId → pending_limit_orders[]

class LimitOrder {
  final String orderId;
  final String time;
  final String symbol;
  final String contractName;
  final String exchangeToken;
  final String action; // 'Buy' | 'Sell'
  final int quantity;
  final double limitPrice;

  const LimitOrder({
    required this.orderId,
    required this.time,
    required this.symbol,
    required this.contractName,
    required this.exchangeToken,
    required this.action,
    required this.quantity,
    required this.limitPrice,
  });

  factory LimitOrder.fromJson(Map<String, dynamic> json) {
    final contractName = json['contract_name'] as String? ?? 'UNKNOWN';
    final symbol = _parseSymbol(contractName);

    final createdAt =
        DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
        DateTime.now();
    final time =
        '${createdAt.hour}.${createdAt.minute.toString().padLeft(2, '0')}';

    final side = json['side'] as String? ?? 'BUY';
    final action = side[0].toUpperCase() + side.substring(1).toLowerCase();

    final raw = json['exchange_token'];
    final exchangeToken = raw is num ? raw.toString() : (raw as String? ?? '');

    return LimitOrder(
      orderId: json['order_id'] as String? ?? '',
      time: time,
      symbol: symbol,
      contractName: contractName,
      exchangeToken: exchangeToken,
      action: action,
      quantity: (json['qty'] as num?)?.toInt() ?? 1,
      limitPrice: (json['limit_price'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static String _parseSymbol(String contractName) {
    var s = contractName.replaceAll(RegExp(r'(FUT|CE|PE)$'), '');
    s = s.replaceAll(RegExp(r'\d{2}[A-Z]{3}$'), '');
    return s.isEmpty ? contractName : s;
  }
}

// ─── Contract Info Model ──────────────────────────────────────────────────────

class ContractInfo {
  final int lotSize;
  final double marginNeeded;
  final double ltp;
  final String ltpStatus;
  final String tradingSymbol;

  const ContractInfo({
    required this.lotSize,
    required this.marginNeeded,
    required this.ltp,
    required this.ltpStatus,
    required this.tradingSymbol,
  });

  factory ContractInfo.fromJson(Map<String, dynamic> json) {
    return ContractInfo(
      lotSize: (json['lot_size'] as num?)?.toInt() ?? 1,
      marginNeeded: (json['margin_needed'] as num?)?.toDouble() ?? 0.0,
      ltp: (json['ltp'] as num?)?.toDouble() ?? 0.0,
      ltpStatus: json['ltp_status']?.toString() ?? 'not_in_feed',
      tradingSymbol: json['trading_symbol']?.toString() ?? '',
    );
  }

  bool get isLive => ltpStatus == 'live';
}

// ─── Positions Response ───────────────────────────────────────────────────────

class PositionsResponse {
  final List<Order> positions;
  final List<LimitOrder> pendingLimitOrders;

  const PositionsResponse({
    required this.positions,
    required this.pendingLimitOrders,
  });
}

// ─── Repository ───────────────────────────────────────────────────────────────

class OrdersRepository {
  static const String _baseUrl = 'http://69.62.75.117:8765';

  Future<List<Order>> fetchOrders(String userId) async {
    final uri = Uri.parse('$_baseUrl/orders/$userId');
    final response = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Failed to load orders (HTTP ${response.statusCode})');
    }

    final List<dynamic> jsonList = jsonDecode(response.body) as List<dynamic>;
    return jsonList
        .map((e) => Order.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetches active positions AND pending limit orders from /positions/:userId.
  Future<PositionsResponse> fetchPositions(String userId) async {
    final uri = Uri.parse('$_baseUrl/positions/$userId');
    final response = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Failed to load positions (HTTP ${response.statusCode})');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    final positions = (json['positions'] as List<dynamic>? ?? [])
        .map((e) => Order.fromJson(e as Map<String, dynamic>))
        .toList();

    final pendingLimitOrders =
        (json['pending_limit_orders'] as List<dynamic>? ?? [])
            .map((e) => LimitOrder.fromJson(e as Map<String, dynamic>))
            .toList();

    return PositionsResponse(
      positions: positions,
      pendingLimitOrders: pendingLimitOrders,
    );
  }

  Future<ContractInfo> fetchContractInfo(String identifier) async {
    final uri = Uri.parse('$_baseUrl/contract/$identifier');
    final response = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 8));

    debugPrint(
      '📡 Contract info [$identifier] → ${response.statusCode}: ${response.body}',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to load contract info (HTTP ${response.statusCode})',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return ContractInfo.fromJson(json);
  }

  Future<void> closeOrder(String orderId, {required int qty}) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/close');
    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'qty': qty}),
        )
        .timeout(const Duration(seconds: 15));

    debugPrint(
      'Close order response: ${response.statusCode} - ${response.body}',
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to close order (HTTP ${response.statusCode})');
    }
  }

  /// Modify the limit price of a pending limit order.
  Future<void> modifyOrder(String orderId, {required double limitPrice}) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/modify');
    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'limit_price': limitPrice}),
        )
        .timeout(const Duration(seconds: 15));

    debugPrint(
      'Modify order [$orderId] → limit_price=$limitPrice: ${response.statusCode} - ${response.body}',
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to modify order (HTTP ${response.statusCode})');
    }
  }

  /// Cancel a pending limit order.
  Future<void> cancelOrder(String orderId) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/cancel');
    final response = await http
        .patch(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    debugPrint(
      'Cancel order [$orderId]: ${response.statusCode} - ${response.body}',
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to cancel order (HTTP ${response.statusCode})');
    }
  }
}

// ─── WS PnL provider ─────────────────────────────────────────────────────────

class PnlWebSocket {
  static const String _wsBase = 'ws://69.62.75.117:8765';

  WebSocketChannel? _channel;
  final _controller = StreamController<Map<String, double>>.broadcast();
  Timer? _pingTimer;

  Stream<Map<String, double>> get ltpStream => _controller.stream;

  void connect(String userId) {
    _channel?.sink.close();
    final uri = Uri.parse('$_wsBase/ws/pnl/$userId');
    _channel = WebSocketChannel.connect(uri);

    _channel!.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          final orders = data['orders'] as List<dynamic>? ?? [];
          final ltpMap = <String, double>{};

          for (final o in orders) {
            final order = o as Map<String, dynamic>;
            final token =
                order['instrument_token']?.toString() ??
                order['exchange_token'] as String? ??
                '';
            final ltp = order['ltp'];
            if (token.isNotEmpty && token != '0' && ltp != null) {
              ltpMap[token] = (ltp as num).toDouble();
            }
          }

          if (ltpMap.isNotEmpty) _controller.add(ltpMap);
        } catch (_) {}
      },
      onError: (_) => _scheduleReconnect(userId),
      onDone: () => _scheduleReconnect(userId),
    );

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        _channel?.sink.add('ping');
      } catch (_) {}
    });
  }

  void _scheduleReconnect(String userId) {
    Future.delayed(const Duration(seconds: 3), () => connect(userId));
  }

  void dispose() {
    _pingTimer?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}

// ─── Open order detail bottom sheet ──────────────────────────────────────────

void _showOrderDetail(
  BuildContext context,
  Order order, {
  VoidCallback? onClosed,
  Stream<Map<String, double>>? ltpStream,
}) {
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E1E1E)
        : Colors.white,
    builder: (context) => SafeArea(
      top: false,
      child: _OrderDetailSheet(
        order: order,
        onClosed: onClosed,
        ltpStream: ltpStream,
      ),
    ),
  );
}

// ─── Limit order detail bottom sheet ─────────────────────────────────────────

void _showLimitOrderDetail(
  BuildContext context,
  LimitOrder order, {
  VoidCallback? onRefresh,
}) {
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E1E1E)
        : Colors.white,
    builder: (context) => SafeArea(
      top: false,
      child: _LimitOrderDetailSheet(order: order, onRefresh: onRefresh),
    ),
  );
}

// ─── _OrderDetailSheet (unchanged — for OPEN orders) ─────────────────────────

class _OrderDetailSheet extends StatefulWidget {
  final Order order;
  final VoidCallback? onClosed;
  final Stream<Map<String, double>>? ltpStream;

  const _OrderDetailSheet({required this.order, this.onClosed, this.ltpStream});

  @override
  State<_OrderDetailSheet> createState() => _OrderDetailSheetState();
}

class _OrderDetailSheetState extends State<_OrderDetailSheet> {
  final _repo = OrdersRepository();
  bool _isClosing = false;
  bool _isCancelling = false;
  late double _currentPrice;
  late int _exitLots;
  ContractInfo? _contractInfo;
  bool _contractLoading = true;
  String? _contractError;
  StreamSubscription<Map<String, double>>? _ltpSub;

  @override
  void initState() {
    super.initState();
    _currentPrice = widget.order.currentPrice;
    _exitLots = 1;

    _ltpSub = widget.ltpStream?.listen((ltpMap) {
      final order = widget.order;
      final ltp =
          ltpMap[order.instrumentToken] ??
          ltpMap[order.exchangeToken] ??
          ltpMap[order.contractName];
      if (ltp != null && mounted) {
        setState(() => _currentPrice = ltp);
      }
    });

    _loadContractInfo();
  }

  String get _contractFetchToken {
    final name = widget.order.contractName;
    if (name.isNotEmpty && name != 'UNKNOWN') return name;
    final registered = ContractTokenRegistry.getTokenFuzzy(name);
    if (registered != null) return registered.toString();
    return widget.order.bestToken;
  }

  Future<void> _loadContractInfo() async {
    setState(() {
      _contractLoading = true;
      _contractError = null;
    });
    try {
      final info = await _repo.fetchContractInfo(_contractFetchToken);
      if (mounted) {
        setState(() {
          _contractInfo = info;
          _contractLoading = false;
          final maxExitLots = (widget.order.quantity / info.lotSize).floor();
          _exitLots = _exitLots.clamp(1, maxExitLots.clamp(1, 99999));
        });
      }
    } catch (e) {
      debugPrint('❌ Contract info error: $e');
      if (mounted) {
        setState(() {
          _contractLoading = false;
          _contractError = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _ltpSub?.cancel();
    super.dispose();
  }

  Future<void> _showQtyDialog() async {
    if (_contractLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Loading contract info, please try again…'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_contractError != null) {
      await _loadContractInfo();
      if (_contractError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contract info unavailable: $_contractError'),
            duration: const Duration(seconds: 3),
            backgroundColor: const Color(0xFFD32F2F),
          ),
        );
        return;
      }
    }

    final order = widget.order;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lotSize = _contractInfo?.lotSize ?? 1;
    final maxLots = (order.quantity / lotSize).floor().clamp(1, 99999);
    int dialogLots = _exitLots.clamp(1, maxLots);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final isBuy = order.action == 'Buy';
            final pnlPerUnit = isBuy
                ? _currentPrice - order.price
                : order.price - _currentPrice;
            final actualQty = dialogLots * lotSize;
            final exitPnl = pnlPerUnit * actualQty;
            final isProfit = exitPnl >= 0;

            return Dialog(
              backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select exit lots',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${order.symbol}  ·  max $maxLots lot${maxLots > 1 ? 's' : ''} (${order.quantity} qty)',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _QtyButton(
                          icon: Icons.remove,
                          onTap: dialogLots > 1
                              ? () => setDialogState(() => dialogLots--)
                              : null,
                          isDark: isDark,
                          size: 40,
                        ),
                        const SizedBox(width: 24),
                        Column(
                          children: [
                            Text(
                              '$dialogLots',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            Text(
                              'lot${dialogLots > 1 ? 's' : ''} (${dialogLots * lotSize} qty)',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.grey.shade400
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 24),
                        _QtyButton(
                          icon: Icons.add,
                          onTap: dialogLots < maxLots
                              ? () => setDialogState(() => dialogLots++)
                              : null,
                          isDark: isDark,
                          size: 40,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (maxLots > 1) ...[
                      SliderTheme(
                        data: SliderTheme.of(dialogContext).copyWith(
                          activeTrackColor: const Color(0xFFD32F2F),
                          inactiveTrackColor: isDark
                              ? Colors.white12
                              : Colors.grey.shade200,
                          thumbColor: const Color(0xFFD32F2F),
                          overlayColor: const Color(
                            0xFFD32F2F,
                          ).withValues(alpha: 0.15),
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                        ),
                        child: Slider(
                          value: dialogLots.toDouble(),
                          min: 1,
                          max: maxLots.toDouble(),
                          divisions: maxLots > 1 ? maxLots - 1 : 1,
                          onChanged: (v) =>
                              setDialogState(() => dialogLots = v.round()),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '1',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                            Text(
                              '$maxLots',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (!_contractLoading && _currentPrice > 0) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 20),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isProfit
                              ? (isDark
                                    ? const Color(
                                        0xFF1B5E20,
                                      ).withValues(alpha: 0.25)
                                    : const Color(0xFFE8F5E9))
                              : (isDark
                                    ? const Color(
                                        0xFFB71C1C,
                                      ).withValues(alpha: 0.25)
                                    : const Color(0xFFFFEBEE)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Est. P&L for $dialogLots lot${dialogLots > 1 ? 's' : ''}',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? Colors.grey.shade300
                                    : Colors.grey.shade700,
                              ),
                            ),
                            Text(
                              '${isProfit ? '+' : ''}₹${exitPnl.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isProfit
                                    ? const Color(0xFF81C784)
                                    : const Color(0xFFE57373),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (_contractLoading) ...[
                      const SizedBox(height: 20),
                      const Center(
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: BorderSide(
                                color: isDark
                                    ? Colors.white24
                                    : Colors.grey.shade300,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFD32F2F),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: const Text(
                              'Confirm',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed == true) {
      await _exitPosition(dialogLots);
    }
  }

  // ── Modify limit price (for market-pending orders) ────────────────────────

  Future<void> _showModifyDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Modify limit price',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.order.symbol}  ·  ${widget.order.action}  ·  ${widget.order.quantity} qty',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black,
                ),
                decoration: InputDecoration(
                  hintText: '0.00',
                  prefixText: '₹  ',
                  prefixStyle: TextStyle(
                    fontSize: 18,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white24 : Colors.grey.shade300,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF1565C0),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.order.action == 'Buy'
                    ? 'Trigger: LTP ≤ new limit price'
                    : 'Trigger: LTP ≥ new limit price',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.grey.shade300,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Update',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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

    // Read the value before dispose — always dispose in finally.
    final rawText = controller.text.trim();
    controller.dispose();

    if (confirmed != true || !mounted) return;

    final newPrice = double.tryParse(rawText);
    if (newPrice == null || newPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid price'),
          backgroundColor: Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isCancelling = true);
    try {
      await _repo.modifyOrder(widget.order.orderId, limitPrice: newPrice);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onClosed?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Limit price updated to ₹${newPrice.toStringAsFixed(2)} for ${widget.order.symbol}',
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade300
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCancelling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to modify order: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Cancel pending order ──────────────────────────────────────────────────

  Future<void> _cancelPendingOrder() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cancel order?',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This will cancel your pending ${widget.order.action.toLowerCase()} order for ${widget.order.symbol}.',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.grey.shade300,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Keep',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Cancel order',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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

    if (confirmed == true) {
      setState(() => _isCancelling = true);
      try {
        await _repo.cancelOrder(widget.order.orderId);
        if (!mounted) return;
        Navigator.pop(context);
        widget.onClosed?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order cancelled for ${widget.order.symbol}'),
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey.shade300
                : Colors.black87,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() => _isCancelling = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to cancel order: $e'),
            backgroundColor: const Color(0xFFD32F2F),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _exitPosition(int lots) async {
    setState(() => _isClosing = true);
    try {
      final lotSize = _contractInfo?.lotSize ?? 1;
      final actualQty = lots * lotSize;
      setState(() => _exitLots = lots);
      await _repo.closeOrder(widget.order.orderId, qty: actualQty);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onClosed?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exited $lots lot(s) ($actualQty qty) of ${widget.order.symbol}',
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade300
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isClosing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to close position: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final isBuy = order.action == 'Buy';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final pnlPerUnit = isBuy
        ? _currentPrice - order.price
        : order.price - _currentPrice;
    final totalPnl = pnlPerUnit * order.quantity;
    final isProfit = totalPnl >= 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  order.symbol,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
              _StatusBadge(status: order.status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${order.action}  ·  ${order.quantity} qty  ·  ${order.time}',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 20),
          Divider(
            height: 1,
            thickness: 1,
            color: isDark ? Colors.white10 : Colors.grey.shade200,
          ),
          const SizedBox(height: 20),
          _DetailRow(
            label: 'Entry price',
            value: '₹${order.price.toStringAsFixed(2)}',
          ),
          const SizedBox(height: 12),
          _DetailRow(
            label: 'Current price',
            value: _currentPrice > 0
                ? '₹${_currentPrice.toStringAsFixed(2)}'
                : '—',
          ),
          const SizedBox(height: 12),
          if (_contractInfo != null) ...[
            _DetailRow(
              label: 'Lot size',
              value: '${_contractInfo!.lotSize} qty',
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Live P&L',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              _currentPrice > 0
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${isProfit ? '+' : ''}₹${totalPnl.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: isProfit
                                ? const Color(0xFF81C784)
                                : const Color(0xFFE57373),
                          ),
                        ),
                        Text(
                          '${isProfit ? '+' : ''}${order.price > 0 ? (pnlPerUnit / order.price * 100).toStringAsFixed(2) : '0.00'}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isProfit
                                ? const Color(0xFF81C784)
                                : const Color(0xFFE57373),
                          ),
                        ),
                      ],
                    )
                  : Text(
                      '—',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade400,
                      ),
                    ),
            ],
          ),
          if (_contractLoading) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  height: 12,
                  width: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Text(
                  'Loading contract info…',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ] else if (_contractError != null) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _loadContractInfo,
              child: Row(
                children: [
                  const Icon(Icons.refresh, size: 14, color: Color(0xFFD32F2F)),
                  const SizedBox(width: 6),
                  Text(
                    'Contract info unavailable — tap to retry',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ],
          if (order.status == OrderStatus.open) ...[
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isClosing ? null : _showQtyDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(
                    0xFFD32F2F,
                  ).withValues(alpha: 0.6),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isClosing
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Exit position',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],

          // ── Pending order actions ───────────────────────────────────────
          if (order.status == OrderStatus.pending) ...[
            const SizedBox(height: 20),
            // Info chip
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0D47A1).withValues(alpha: 0.2)
                    : const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: isDark
                        ? const Color(0xFF64B5F6)
                        : const Color(0xFF1565C0),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Waiting for limit price to be reached',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? const Color(0xFF64B5F6)
                            : const Color(0xFF1565C0),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_isCancelling)
              const Center(
                child: SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _cancelPendingOrder,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel order'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: const Color(0xFFD32F2F),
                        side: const BorderSide(color: Color(0xFFD32F2F)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _showModifyDialog,
                      icon: const Icon(Icons.edit_rounded, size: 16),
                      label: const Text('Modify price'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

// ─── _LimitOrderDetailSheet (for PENDING limit orders) ───────────────────────

class _LimitOrderDetailSheet extends StatefulWidget {
  final LimitOrder order;
  final VoidCallback? onRefresh;

  const _LimitOrderDetailSheet({required this.order, this.onRefresh});

  @override
  State<_LimitOrderDetailSheet> createState() => _LimitOrderDetailSheetState();
}

class _LimitOrderDetailSheetState extends State<_LimitOrderDetailSheet> {
  final _repo = OrdersRepository();
  bool _isBusy = false;

  // ── Modify dialog ─────────────────────────────────────────────────────────

  Future<void> _showModifyDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController(
      text: widget.order.limitPrice.toStringAsFixed(2),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Modify limit price',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.order.symbol}  ·  ${widget.order.action}  ·  ${widget.order.quantity} qty',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                autofocus: true,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black,
                ),
                decoration: InputDecoration(
                  prefixText: '₹  ',
                  prefixStyle: TextStyle(
                    fontSize: 18,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white24 : Colors.grey.shade300,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF1565C0),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.order.action == 'Buy'
                    ? 'Trigger: LTP ≤ new limit price'
                    : 'Trigger: LTP ≥ new limit price',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.grey.shade300,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Update',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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

    final rawText = controller.text.trim();
    controller.dispose();

    if (confirmed != true || !mounted) return;

    final newPrice = double.tryParse(rawText);
    if (newPrice == null || newPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid price'),
          backgroundColor: Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await _modifyOrder(newPrice);
  }

  Future<void> _modifyOrder(double newPrice) async {
    setState(() => _isBusy = true);
    try {
      await _repo.modifyOrder(widget.order.orderId, limitPrice: newPrice);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onRefresh?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Limit price updated to ₹${newPrice.toStringAsFixed(2)} for ${widget.order.symbol}',
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade300
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to modify order: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Cancel confirm dialog ─────────────────────────────────────────────────

  Future<void> _showCancelConfirm() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cancel order?',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This will cancel your pending ${widget.order.action.toLowerCase()} order for ${widget.order.symbol} at ₹${widget.order.limitPrice.toStringAsFixed(2)}.',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.grey.shade300,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Keep',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Cancel order',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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

    if (confirmed == true) {
      await _cancelOrder();
    }
  }

  Future<void> _cancelOrder() async {
    setState(() => _isBusy = true);
    try {
      await _repo.cancelOrder(widget.order.orderId);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onRefresh?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order cancelled for ${widget.order.symbol}'),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade300
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to cancel order: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final isBuy = order.action == 'Buy';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  order.symbol,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
              // Limit badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF4A148C).withValues(alpha: 0.3)
                      : const Color(0xFFEDE7F6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'LIMIT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? const Color(0xFFCE93D8)
                        : const Color(0xFF6A1B9A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${order.action}  ·  ${order.quantity} qty  ·  ${order.time}',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 20),
          Divider(
            height: 1,
            thickness: 1,
            color: isDark ? Colors.white10 : Colors.grey.shade200,
          ),
          const SizedBox(height: 20),

          // ── Details ────────────────────────────────────────────────────────
          _DetailRow(
            label: 'Limit price',
            value: '₹${order.limitPrice.toStringAsFixed(2)}',
          ),
          const SizedBox(height: 12),
          _DetailRow(label: 'Quantity', value: '${order.quantity} qty'),
          const SizedBox(height: 12),
          _DetailRow(
            label: 'Trigger condition',
            value: isBuy ? 'LTP ≤ limit price' : 'LTP ≥ limit price',
          ),
          const SizedBox(height: 12),

          // ── Status info box ────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF0D47A1).withValues(alpha: 0.2)
                  : const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: isDark
                      ? const Color(0xFF64B5F6)
                      : const Color(0xFF1565C0),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waiting for market to reach ₹${order.limitPrice.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? const Color(0xFF64B5F6)
                          : const Color(0xFF1565C0),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Action buttons ─────────────────────────────────────────────────
          if (_isBusy)
            const Center(
              child: SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Row(
              children: [
                // Cancel order button
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showCancelConfirm,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Cancel order'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      foregroundColor: const Color(0xFFD32F2F),
                      side: const BorderSide(color: Color(0xFFD32F2F)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Modify button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _showModifyDialog,
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: const Text('Modify price'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─── Qty stepper button ───────────────────────────────────────────────────────

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool isDark;
  final double size;

  const _QtyButton({
    required this.icon,
    required this.onTap,
    required this.isDark,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.3,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isDark ? Colors.white10 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(size / 4),
          ),
          child: Icon(
            icon,
            size: size * 0.5,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ),
    );
  }
}

// ─── Detail row ───────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ],
    );
  }
}

// ─── Status badge ─────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (label, bg, fg) = switch (status) {
      OrderStatus.open || OrderStatus.pending => (
        status == OrderStatus.pending ? 'Pending' : 'Open',
        isDark
            ? const Color(0xFF0D47A1).withValues(alpha: 0.3)
            : const Color(0xFFE3F2FD),
        isDark ? const Color(0xFF64B5F6) : const Color(0xFF1565C0),
      ),
      OrderStatus.closed => (
        'Closed',
        isDark
            ? const Color(0xFF1B5E20).withValues(alpha: 0.3)
            : const Color(0xFFE8F5E9),
        isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      ),
      OrderStatus.cancelled => (
        'Cancelled',
        isDark ? Colors.white10 : const Color(0xFFFAFAFA),
        isDark ? Colors.grey.shade400 : Colors.grey,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

// ─── Combined pending item (union type) ──────────────────────────────────────
// The Pending tab shows both market-order pending items (Order) and
// limit orders (LimitOrder). This sealed class wraps both.

sealed class _PendingItem {}

class _PendingOrder extends _PendingItem {
  final Order order;
  _PendingOrder(this.order);
}

class _PendingLimit extends _PendingItem {
  final LimitOrder order;
  _PendingLimit(this.order);
}

// ─── Screen + Tabs ────────────────────────────────────────────────────────────

class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _repo = OrdersRepository();
  final _pnlWs = PnlWebSocket();

  // orders from /orders/:userId (open, closed, cancelled)
  late Future<List<Order>> _ordersFuture;
  // limit orders from /positions/:userId
  late Future<List<LimitOrder>> _limitOrdersFuture;

  final Map<String, double> _ltpMap = {};
  StreamSubscription<Map<String, double>>? _ltpSub;

  String get _userId => ref.read(authProvider.notifier).userId ?? 'unknown';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _ordersFuture = _repo.fetchOrders(_userId);
    _limitOrdersFuture = _fetchLimitOrders();

    _pnlWs.connect(_userId);
    _ltpSub = _pnlWs.ltpStream.listen((ltpMap) {
      if (mounted) setState(() => _ltpMap.addAll(ltpMap));
    });
  }

  Future<List<LimitOrder>> _fetchLimitOrders() async {
    final positions = await _repo.fetchPositions(_userId);
    return positions.pendingLimitOrders;
  }

  @override
  void dispose() {
    _ltpSub?.cancel();
    _pnlWs.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _ordersFuture = _repo.fetchOrders(_userId);
      _limitOrdersFuture = _fetchLimitOrders();
    });
  }

  List<Order> _withLivePrices(List<Order> orders) {
    return orders.map((o) {
      final ltp =
          _ltpMap[o.instrumentToken] ??
          _ltpMap[o.exchangeToken] ??
          _ltpMap[o.contractName];
      return ltp != null && ltp > 0 ? o.copyWithLtp(ltp) : o;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark ? const Color(0xFF121212) : Colors.white,
      // We need both futures to render fully. Use a nested FutureBuilder approach.
      child: FutureBuilder<List<Order>>(
        future: _ordersFuture,
        builder: (context, ordersSnap) {
          // Show a spinner only on the very first load (no data yet).
          if (ordersSnap.connectionState == ConnectionState.waiting &&
              !ordersSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (ordersSnap.hasError) {
            return _buildError(isDark, ordersSnap.error.toString(), _refresh);
          }

          return FutureBuilder<List<LimitOrder>>(
            future: _limitOrdersFuture,
            builder: (context, limitSnap) {
              final allOrders = _withLivePrices(ordersSnap.data ?? []);
              final limitOrders = limitSnap.data ?? [];

              return Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    controller: _tabController,
                    labelColor: isDark ? Colors.white : Colors.black,
                    unselectedLabelColor: Colors.grey.shade500,
                    indicatorColor: isDark ? Colors.white : Colors.black,
                    indicatorWeight: 2,
                    dividerColor: Colors.transparent,
                    labelStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    unselectedLabelStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                    tabs: [
                      const Tab(text: 'All'),
                      // Show badge on Pending tab when there are limit orders
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Pending'),
                            if (limitOrders.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(
                                          0xFF4A148C,
                                        ).withValues(alpha: 0.4)
                                      : const Color(0xFFEDE7F6),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${limitOrders.length}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? const Color(0xFFCE93D8)
                                        : const Color(0xFF6A1B9A),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Tab(text: 'Open'),
                      const Tab(text: 'Cancelled'),
                    ],
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: isDark ? Colors.white10 : Colors.grey.shade200,
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        // ── All tab ─────────────────────────────────────────
                        _buildOrderList(isDark: isDark, orders: allOrders),

                        // ── Pending tab ─────────────────────────────────────
                        _buildPendingTab(
                          isDark: isDark,
                          orders: allOrders
                              .where((o) => o.status == OrderStatus.pending)
                              .toList(),
                          limitOrders: limitOrders,
                          isLoadingLimits:
                              limitSnap.connectionState ==
                              ConnectionState.waiting,
                        ),

                        // ── Open tab ────────────────────────────────────────
                        _buildOrderList(
                          isDark: isDark,
                          orders: allOrders
                              .where((o) => o.status == OrderStatus.open)
                              .toList(),
                        ),

                        // ── Cancelled tab ───────────────────────────────────
                        _buildOrderList(
                          isDark: isDark,
                          orders: allOrders
                              .where((o) => o.status == OrderStatus.cancelled)
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ── Tab builders ────────────────────────────────────────────────────────────

  Widget _buildOrderList({required bool isDark, required List<Order> orders}) {
    if (orders.isEmpty) {
      return _emptyState(isDark);
    }
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 100,
        ),
        itemCount: orders.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          color: isDark ? Colors.white10 : Colors.grey.shade100,
          indent: 16,
          endIndent: 16,
        ),
        itemBuilder: (context, index) => _OrderTile(
          order: orders[index],
          onTap: () => _showOrderDetail(
            context,
            orders[index],
            onClosed: _refresh,
            ltpStream: _pnlWs.ltpStream,
          ),
        ),
      ),
    );
  }

  Widget _buildPendingTab({
    required bool isDark,
    required List<Order> orders,
    required List<LimitOrder> limitOrders,
    required bool isLoadingLimits,
  }) {
    // Build a unified list: limit orders first (they are actionable), then
    // market-pending orders below.
    final items = <_PendingItem>[
      ...limitOrders.map(_PendingLimit.new),
      ...orders.map(_PendingOrder.new),
    ];

    if (items.isEmpty && !isLoadingLimits) {
      return _emptyState(isDark);
    }

    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 100,
        ),
        // +1 for the optional loading spinner row when limits are still loading
        itemCount: items.length + (isLoadingLimits ? 1 : 0),
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          color: isDark ? Colors.white10 : Colors.grey.shade100,
          indent: 16,
          endIndent: 16,
        ),
        itemBuilder: (context, index) {
          // Loading shimmer row at the top while /positions is in-flight
          if (isLoadingLimits && index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const SizedBox(
                    height: 14,
                    width: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Loading limit orders…',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  ),
                ],
              ),
            );
          }

          final itemIndex = isLoadingLimits ? index - 1 : index;
          final item = items[itemIndex];

          return switch (item) {
            _PendingOrder(order: final o) => _OrderTile(
              order: o,
              onTap: () => _showOrderDetail(
                context,
                o,
                onClosed: _refresh,
                ltpStream: _pnlWs.ltpStream,
              ),
            ),
            _PendingLimit(order: final lo) => _LimitOrderTile(
              order: lo,
              onTap: () =>
                  _showLimitOrderDetail(context, lo, onRefresh: _refresh),
            ),
          };
        },
      ),
    );
  }

  Widget _emptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: isDark ? Colors.white10 : Colors.grey.shade200,
          ),
          const SizedBox(height: 16),
          Text(
            'No orders here',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildError(bool isDark, String error, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 52,
              color: isDark ? Colors.white24 : Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load orders',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Order tile (for OPEN / ALL / CANCELLED orders) ───────────────────────────

class _OrderTile extends StatelessWidget {
  final Order order;
  final VoidCallback onTap;
  const _OrderTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isBuy = order.action == 'Buy';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isOpen =
        order.status == OrderStatus.open || order.status == OrderStatus.pending;
    final hasLivePrice = order.currentPrice > 0 && isOpen;

    final pnlPerUnit = isBuy
        ? order.currentPrice - order.price
        : order.price - order.currentPrice;
    final totalPnl = pnlPerUnit * order.quantity;
    final isProfit = totalPnl >= 0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                order.time,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.symbol,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isBuy
                              ? (isDark
                                    ? const Color(
                                        0xFF1B5E20,
                                      ).withValues(alpha: 0.3)
                                    : const Color(0xFFE8F5E9))
                              : (isDark
                                    ? const Color(
                                        0xFFB71C1C,
                                      ).withValues(alpha: 0.3)
                                    : const Color(0xFFFFEBEE)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          order.action.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: isBuy
                                ? const Color(0xFF81C784)
                                : const Color(0xFFE57373),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${order.quantity} qty  ·  avg ₹${order.price.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  order.currentPrice > 0
                      ? '₹${order.currentPrice.toStringAsFixed(2)}'
                      : '₹${order.price.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                const SizedBox(height: 4),
                hasLivePrice
                    ? Text(
                        '${isProfit ? '+' : ''}₹${totalPnl.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isProfit
                              ? const Color(0xFF81C784)
                              : const Color(0xFFE57373),
                        ),
                      )
                    : Text(
                        '₹${order.totalValue.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Limit order tile (for PENDING limit orders) ──────────────────────────────

class _LimitOrderTile extends StatelessWidget {
  final LimitOrder order;
  final VoidCallback onTap;
  const _LimitOrderTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isBuy = order.action == 'Buy';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                order.time,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.symbol,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // BUY/SELL badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isBuy
                              ? (isDark
                                    ? const Color(
                                        0xFF1B5E20,
                                      ).withValues(alpha: 0.3)
                                    : const Color(0xFFE8F5E9))
                              : (isDark
                                    ? const Color(
                                        0xFFB71C1C,
                                      ).withValues(alpha: 0.3)
                                    : const Color(0xFFFFEBEE)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          order.action.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: isBuy
                                ? const Color(0xFF81C784)
                                : const Color(0xFFE57373),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // LIMIT badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF4A148C).withValues(alpha: 0.3)
                              : const Color(0xFFEDE7F6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'LIMIT',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? const Color(0xFFCE93D8)
                                : const Color(0xFF6A1B9A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${order.quantity} qty',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Right side: limit price + trigger hint
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${order.limitPrice.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 11,
                      color: isDark
                          ? const Color(0xFF64B5F6)
                          : const Color(0xFF1565C0),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      isBuy ? 'LTP ≤ limit' : 'LTP ≥ limit',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? const Color(0xFF64B5F6)
                            : const Color(0xFF1565C0),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
