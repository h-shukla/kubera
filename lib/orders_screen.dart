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
  final double limitPrice;
  final double exitLimitPrice;
  final int exitLimitQty;
  final double stopLossPrice;
  final int stopLossQty;
  // Tradebook enrichment
  final double? realisedPnl;
  final double? exitPrice;
  final String leg;

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
    required this.limitPrice,
    this.exitLimitPrice = 0.0,
    this.exitLimitQty = 0,
    this.stopLossPrice = 0.0,
    this.stopLossQty = 0,
    this.realisedPnl,
    this.exitPrice,
    this.leg = '',
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
    limitPrice: limitPrice,
    exitLimitPrice: exitLimitPrice,
    exitLimitQty: exitLimitQty,
    stopLossPrice: stopLossPrice,
    stopLossQty: stopLossQty,
    realisedPnl: realisedPnl,
    exitPrice: exitPrice,
    leg: leg,
  );

  Order copyWithTradebook({double? realisedPnl, double? exitPrice}) => Order(
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
    currentPrice: currentPrice,
    limitPrice: limitPrice,
    exitLimitPrice: exitLimitPrice,
    exitLimitQty: exitLimitQty,
    stopLossPrice: stopLossPrice,
    stopLossQty: stopLossQty,
    realisedPnl: realisedPnl ?? this.realisedPnl,
    exitPrice: exitPrice ?? this.exitPrice,
    leg: leg,
  );

  bool get hasLimitExit => exitLimitPrice > 0;
  bool get hasStopLoss => stopLossPrice > 0;

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
    final limitPrice = (json['limit_price'] as num?)?.toDouble() ?? 0.0;

    final exitLimitPrice =
        (json['exit_limit_price'] as num?)?.toDouble() ?? 0.0;
    final exitLimitQty = (json['exit_limit_qty'] as num?)?.toInt() ?? 0;
    final stopLossPrice =
        (json['stop_loss_price'] as num?)?.toDouble() ?? 0.0;
    final stopLossQty = (json['stop_loss_qty'] as num?)?.toInt() ?? 0;

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
      limitPrice: limitPrice,
      exitLimitPrice: exitLimitPrice,
      exitLimitQty: exitLimitQty,
      stopLossPrice: stopLossPrice,
      stopLossQty: stopLossQty,
    );
  }

  /// Build an Order directly from a tradebook entry (closed/cancelled trades).
  factory Order.fromTradebook(Map<String, dynamic> json) {
    final rawDate =
        json['timestamp']?.toString() ??
        json['closed_at']?.toString() ??
        json['updated_at']?.toString() ??
        json['trade_date_time']?.toString() ??
        '';
    final dt = DateTime.tryParse(rawDate)?.toLocal() ?? DateTime.now();
    final time = '${dt.hour}.${dt.minute.toString().padLeft(2, '0')}';

    final contractName =
        json['contract_name']?.toString() ??
        json['tradingsymbol']?.toString() ??
        'UNKNOWN';
    final symbol = _parseSymbol(contractName);

    final side =
        json['side']?.toString() ?? json['action']?.toString() ?? 'BUY';
    final action = side[0].toUpperCase() + side.substring(1).toLowerCase();

    final qty =
        (json['qty'] as num?)?.toInt() ??
        int.tryParse(json['quantity']?.toString() ?? '') ??
        1;

    final price = (json['price'] as num?)?.toDouble() ?? 0.0;

    final realisedPnl = json['realised_pnl'] != null
        ? double.tryParse(json['realised_pnl'].toString())
        : null;

    final leg = json['leg']?.toString() ?? '';

    // Tradebook entries are always closed trades
    final rawStatus = (json['status'] as String? ?? 'CLOSED').toUpperCase();
    final status = switch (rawStatus) {
      'CANCELLED' || 'CANCELED' => OrderStatus.cancelled,
      _ => OrderStatus.closed,
    };

    final instrumentTokenInt = (json['instrument_token'] as num?)?.toInt() ?? 0;
    final raw = json['exchange_token'];
    final exchangeToken = instrumentTokenInt > 0
        ? instrumentTokenInt.toString()
        : (raw is num ? raw.toString() : 'UNKNOWN');

    return Order(
      orderId: json['order_id']?.toString() ?? '',
      time: time,
      symbol: symbol,
      contractName: contractName,
      exchangeToken: exchangeToken,
      instrumentToken: instrumentTokenInt.toString(),
      action: action,
      quantity: qty,
      price: price,
      totalValue: price * qty,
      status: status,
      currentPrice: price,
      limitPrice: 0.0,
      realisedPnl: realisedPnl,
      leg: leg,
    );
  }

  static String _parseSymbol(String contractName) {
    var s = contractName.replaceAll(RegExp(r'(FUT|CE|PE)$'), '');
    s = s.replaceAll(RegExp(r'\d{2}[A-Z]{3}$'), '');
    return s.isEmpty ? contractName : s;
  }
}

// ─── Tradebook Entry Model ────────────────────────────────────────────────────

class TradeBookEntry {
  final String orderId;
  final DateTime tradeDateTime;
  final String contractName;
  final String action;
  final int quantity;
  final double tradePrice;
  final String exchange;
  final double? pnl;
  final String leg;

  const TradeBookEntry({
    required this.orderId,
    required this.tradeDateTime,
    required this.contractName,
    required this.action,
    required this.quantity,
    required this.tradePrice,
    required this.exchange,
    required this.leg,
    this.pnl,
  });

  factory TradeBookEntry.fromJson(Map<String, dynamic> json) {
    final rawDate =
        json['timestamp']?.toString() ??
        json['closed_at']?.toString() ??
        json['updated_at']?.toString() ??
        json['trade_date_time']?.toString() ??
        '';
    final dt = DateTime.tryParse(rawDate)?.toLocal() ?? DateTime.now();

    final symbol =
        json['contract_name']?.toString() ??
        json['tradingsymbol']?.toString() ??
        '-';
    final side =
        json['side']?.toString() ??
        json['action']?.toString() ??
        json['transaction_type']?.toString() ??
        'BUY';
    final qty =
        (json['qty'] as num?)?.toInt() ??
        int.tryParse(json['quantity']?.toString() ?? '') ??
        0;
    final price = (json['price'] as num?)?.toDouble() ?? 0.0;
    final exchange = json['exchange']?.toString() ?? '';
    final leg = json['leg']?.toString() ?? '';
    final pnl = json['realised_pnl'] != null
        ? double.tryParse(json['realised_pnl'].toString())
        : null;

    return TradeBookEntry(
      orderId: json['order_id']?.toString() ?? '',
      tradeDateTime: dt,
      contractName: symbol,
      action: side.toUpperCase(),
      quantity: qty,
      tradePrice: price,
      exchange: exchange,
      leg: leg,
      pnl: pnl,
    );
  }
}

// ─── Limit Order Model ────────────────────────────────────────────────────────

class LimitOrder {
  final String orderId;
  final String time;
  final String symbol;
  final String contractName;
  final String exchangeToken;
  final String action;
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

// ─── Combined screen data ─────────────────────────────────────────────────────

class OrdersScreenData {
  final List<Order> orders;
  final List<LimitOrder> limitOrders;
  final List<TradeBookEntry> tradeBookEntries;

  const OrdersScreenData({
    required this.orders,
    required this.limitOrders,
    required this.tradeBookEntries,
  });
}

// ─── Repository ───────────────────────────────────────────────────────────────

class OrdersRepository {
  static const String _baseUrl = 'http://69.62.75.117:8765';

  Future<List<Order>> fetchOrders(String userId) async {
    final uri = Uri.parse('$_baseUrl/orders/$userId');
    debugPrint('📡 USER ID is $userId');
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

  Future<List<TradeBookEntry>> fetchTradebook(String userId) async {
    final uri = Uri.parse('$_baseUrl/tradebook/$userId');
    final response = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

    debugPrint('📡 Tradebook [$userId] → ${response.statusCode}');

    if (response.statusCode != 200) {
      throw Exception('Failed to load tradebook (HTTP ${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);

    List<dynamic> raw = [];
    if (decoded is Map && decoded['trades'] is List) {
      raw = decoded['trades'] as List<dynamic>;
    } else if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map && decoded['data'] is List) {
      raw = decoded['data'] as List<dynamic>;
    }

    return raw
        .map((e) => TradeBookEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetches orders + positions + tradebook in parallel and merges the results.
  /// Strategy:
  ///   • Live data (OPEN / PENDING) comes from /orders and /positions as before.
  ///   • CLOSED / CANCELLED orders are enriched with tradebook P&L where
  ///     order_id matches an EXIT leg in the tradebook.
  ///   • Tradebook EXIT entries whose order_id is NOT already in /orders are
  ///     surfaced as synthetic closed Orders so nothing is missed.
  Future<OrdersScreenData> fetchAll(String userId) async {
    final results = await Future.wait([
      fetchOrders(userId),
      fetchPositions(userId),
      fetchTradebook(userId),
    ]);

    final orders = results[0] as List<Order>;
    final positionsResp = results[1] as PositionsResponse;
    final tbEntries = results[2] as List<TradeBookEntry>;

    // Build a lookup: orderId → tradebook EXIT entry (for P&L enrichment)
    final tbExitByOrderId = <String, TradeBookEntry>{};
    for (final tb in tbEntries) {
      if (tb.leg == 'EXIT' && tb.orderId.isNotEmpty) {
        tbExitByOrderId[tb.orderId] = tb;
      }
    }

    // Enrich existing closed/cancelled orders with P&L from tradebook
    final knownOrderIds = <String>{};
    final enriched = orders.map((o) {
      knownOrderIds.add(o.orderId);
      if (o.status == OrderStatus.closed || o.status == OrderStatus.cancelled) {
        final tb = tbExitByOrderId[o.orderId];
        if (tb != null) {
          return o.copyWithTradebook(
            realisedPnl: tb.pnl,
            exitPrice: tb.tradePrice,
          );
        }
      }
      return o;
    }).toList();

    // Synthetic closed orders: EXIT legs in tradebook not already in /orders
    final syntheticClosed = <Order>[];
    for (final tb in tbEntries) {
      if (tb.leg == 'EXIT' &&
          tb.orderId.isNotEmpty &&
          !knownOrderIds.contains(tb.orderId)) {
        syntheticClosed.add(
          Order(
            orderId: tb.orderId,
            time:
                '${tb.tradeDateTime.hour}.${tb.tradeDateTime.minute.toString().padLeft(2, '0')}',
            symbol: Order._parseSymbol(tb.contractName),
            contractName: tb.contractName,
            exchangeToken: 'UNKNOWN',
            instrumentToken: '0',
            action:
                tb.action[0].toUpperCase() +
                tb.action.substring(1).toLowerCase(),
            quantity: tb.quantity,
            price: tb.tradePrice,
            totalValue: tb.tradePrice * tb.quantity,
            status: OrderStatus.closed,
            currentPrice: tb.tradePrice,
            limitPrice: 0.0,
            realisedPnl: tb.pnl,
            exitPrice: tb.tradePrice,
            leg: tb.leg,
          ),
        );
      }
    }

    return OrdersScreenData(
      orders: [...enriched, ...syntheticClosed],
      limitOrders: positionsResp.pendingLimitOrders,
      tradeBookEntries: tbEntries,
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

  Future<Map<String, dynamic>> fetchOrderDetail(String orderId) async {
    final uri = Uri.parse('$_baseUrl/orders/detail/$orderId');
    final response = await http
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to load order details (HTTP ${response.statusCode})',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
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

    if (response.statusCode != 200 && response.statusCode != 204) {
      String detail = 'Failed to close order (HTTP ${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception(detail);
    }
  }

  Future<void> setExitLimitPrice(
    String orderId, {
    required double exitLimitPrice,
    int? exitLimitQty,
  }) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/modify');
    final body = <String, dynamic>{'exit_limit_price': exitLimitPrice};
    if (exitLimitQty != null) body['exit_limit_qty'] = exitLimitQty;

    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 204) {
      String detail = 'Failed to set limit exit (HTTP ${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception(detail);
    }
  }

  /// Registers a new stop-loss through the close endpoint. The backend uses
  /// `qty` here because this call creates the automatic close instruction.
  Future<void> setStopLossPrice(
    String orderId, {
    required double stopLossPrice,
    int? stopLossQty,
  }) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/close');
    final body = <String, dynamic>{'stop_loss_price': stopLossPrice};
    if (stopLossQty != null) body['qty'] = stopLossQty;

    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 204) {
      String detail =
          'Failed to set stop-loss (HTTP ${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception(detail);
    }
  }

  /// Modifies or clears an existing stop-loss through the modify endpoint.
  Future<void> modifyStopLoss(
    String orderId, {
    required double stopLossPrice,
    int? stopLossQty,
  }) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/modify');
    final body = <String, dynamic>{'stop_loss_price': stopLossPrice};
    if (stopLossQty != null) body['stop_loss_qty'] = stopLossQty;

    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 204) {
      String detail =
          'Failed to modify stop-loss (HTTP ${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw Exception(detail);
    }
  }

  Future<void> modifyOrder(String orderId, {required double limitPrice}) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/modify');
    final response = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'limit_price': limitPrice}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to modify order (HTTP ${response.statusCode})');
    }
  }

  Future<void> cancelOrder(String orderId) async {
    final uri = Uri.parse('$_baseUrl/orders/$orderId/cancel');
    final response = await http
        .patch(uri, headers: {'Content-Type': 'application/json'})
        .timeout(const Duration(seconds: 15));

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

// ─── _OrderDetailSheet ────────────────────────────────────────────────────────

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
  bool _isSettingLimitExit = false;
  bool _isSettingStopLoss = false;
  late double _currentPrice;
  late int _exitLots;
  ContractInfo? _contractInfo;
  bool _contractLoading = true;
  String? _contractError;
  StreamSubscription<Map<String, double>>? _ltpSub;

  late double _exitLimitPrice;
  late int _exitLimitQty;
  late double _stopLossPrice;
  late int _stopLossQty;

  TextEditingController? _limitExitPriceController;
  TextEditingController? _stopLossPriceController;
  TextEditingController? _modifyPriceController;

  @override
  void initState() {
    super.initState();
    _currentPrice = widget.order.currentPrice;
    _exitLots = 1;
    _exitLimitPrice = widget.order.exitLimitPrice;
    _exitLimitQty = widget.order.exitLimitQty;
    _stopLossPrice = widget.order.stopLossPrice;
    _stopLossQty = widget.order.stopLossQty;

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

    // Only load contract info for actionable (open/pending) orders
    if (widget.order.status == OrderStatus.open ||
        widget.order.status == OrderStatus.pending) {
      _loadContractInfo();
    } else {
      setState(() => _contractLoading = false);
    }
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
    _limitExitPriceController?.dispose();
    _stopLossPriceController?.dispose();
    _modifyPriceController?.dispose();
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

    if (confirmed == true) await _exitPosition(dialogLots);
  }

  Future<void> _showLimitExitDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final order = widget.order;
    final isBuy = order.action == 'Buy';
    final lotSize = _contractInfo?.lotSize ?? 1;
    final maxLots = (order.quantity / lotSize).floor().clamp(1, 99999);

    final suggestedPrice = _exitLimitPrice > 0
        ? _exitLimitPrice
        : _currentPrice > 0
        ? _currentPrice
        : order.price;

    _limitExitPriceController = TextEditingController(
      text: suggestedPrice > 0 ? suggestedPrice.toStringAsFixed(2) : '',
    );
    final priceController = _limitExitPriceController!;

    int dialogLots = _exitLimitQty > 0
        ? (_exitLimitQty / lotSize).round().clamp(1, maxLots)
        : maxLots;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return Dialog(
            backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(dialogContext).viewInsets.bottom,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _exitLimitPrice > 0
                                ? 'Update limit exit'
                                : 'Set limit exit',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                        ),
                        if (_exitLimitPrice > 0)
                          GestureDetector(
                            onTap: () => Navigator.pop(dialogContext, {
                              'action': 'clear',
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white10
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Clear',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.grey.shade400
                                      : Colors.grey.shade600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${order.symbol}  ·  ${order.action}  ·  ${order.quantity} qty',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Target price',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: priceController,
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
                          color: isDark
                              ? Colors.grey.shade400
                              : Colors.grey.shade600,
                        ),
                        suffixText: _currentPrice > 0
                            ? 'LTP ₹${_currentPrice.toStringAsFixed(2)}'
                            : null,
                        suffixStyle: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.grey.shade500
                              : Colors.grey.shade600,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: isDark
                                ? Colors.white24
                                : Colors.grey.shade300,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFF388E3C),
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
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 13,
                          color: Colors.grey.shade500,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isBuy
                              ? 'Exits when LTP ≥ target (sell high)'
                              : 'Exits when LTP ≤ target (buy back low)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Exit lots',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _QtyButton(
                          icon: Icons.remove,
                          onTap: dialogLots > 1
                              ? () => setDialogState(() => dialogLots--)
                              : null,
                          isDark: isDark,
                          size: 36,
                        ),
                        const SizedBox(width: 20),
                        Column(
                          children: [
                            Text(
                              '$dialogLots',
                              style: TextStyle(
                                fontSize: 28,
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
                        const SizedBox(width: 20),
                        _QtyButton(
                          icon: Icons.add,
                          onTap: dialogLots < maxLots
                              ? () => setDialogState(() => dialogLots++)
                              : null,
                          isDark: isDark,
                          size: 36,
                        ),
                      ],
                    ),
                    if (maxLots > 1) ...[
                      const SizedBox(height: 4),
                      SliderTheme(
                        data: SliderTheme.of(dialogContext).copyWith(
                          activeTrackColor: const Color(0xFF388E3C),
                          inactiveTrackColor: isDark
                              ? Colors.white12
                              : Colors.grey.shade200,
                          thumbColor: const Color(0xFF388E3C),
                          overlayColor: const Color(
                            0xFF388E3C,
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
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(dialogContext, {
                              'action': 'cancel',
                            }),
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
                            onPressed: () => Navigator.pop(dialogContext, {
                              'action': 'set',
                              'price': priceController.text.trim(),
                              'lots': dialogLots,
                            }),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF388E3C),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              _exitLimitPrice > 0 ? 'Update' : 'Set target',
                              style: const TextStyle(
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
        },
      ),
    );

    if (result == null || !mounted) return;
    final action = result['action'] as String?;

    if (action == 'clear') {
      await _clearLimitExit();
      return;
    }
    if (action != 'set') return;

    final newPrice = double.tryParse(result['price'] as String? ?? '');
    if (newPrice == null || newPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid target price'),
          backgroundColor: Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final lots = result['lots'] as int? ?? maxLots;
    final lotSize2 = _contractInfo?.lotSize ?? 1;
    await _applyLimitExit(newPrice, lots * lotSize2);
  }

  Future<void> _applyLimitExit(double price, int qty) async {
    setState(() => _isSettingLimitExit = true);
    try {
      await _repo.setExitLimitPrice(
        widget.order.orderId,
        exitLimitPrice: price,
        exitLimitQty: qty,
      );
      if (!mounted) return;
      setState(() {
        _exitLimitPrice = price;
        _exitLimitQty = qty;
        _isSettingLimitExit = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Limit exit set at ₹${price.toStringAsFixed(2)} for ${widget.order.symbol}',
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade800
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
      widget.onClosed?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSettingLimitExit = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to set limit exit: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _clearLimitExit() async {
    setState(() => _isSettingLimitExit = true);
    try {
      await _repo.setExitLimitPrice(widget.order.orderId, exitLimitPrice: 0);
      if (!mounted) return;
      setState(() {
        _exitLimitPrice = 0;
        _exitLimitQty = 0;
        _isSettingLimitExit = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Limit exit cleared for ${widget.order.symbol}'),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade800
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
      widget.onClosed?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSettingLimitExit = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to clear limit exit: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showStopLossDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final order = widget.order;
    final isBuy = order.action == 'Buy';
    final suggestedPrice = _stopLossPrice > 0
        ? _stopLossPrice
        : _currentPrice > 0
        ? _currentPrice
        : order.price;

    _stopLossPriceController?.dispose();
    _stopLossPriceController = TextEditingController(
      text: suggestedPrice > 0 ? suggestedPrice.toStringAsFixed(2) : '',
    );
    final priceController = _stopLossPriceController!;
    final qtyController = TextEditingController(
      text: (_stopLossQty > 0 ? _stopLossQty : order.quantity).toString(),
    );

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(dialogContext).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _stopLossPrice > 0
                            ? 'Update stop-loss'
                            : 'Set stop-loss',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                    ),
                    if (_stopLossPrice > 0)
                      GestureDetector(
                        onTap: () => Navigator.pop(dialogContext, {
                          'action': 'clear',
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white10
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Clear',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.grey.shade400
                                  : Colors.grey.shade600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${order.symbol}  ·  ${order.action}  ·  ${order.quantity} qty',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Stop-loss price',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: priceController,
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
                    suffixText: _currentPrice > 0
                        ? 'LTP ₹${_currentPrice.toStringAsFixed(2)}'
                        : null,
                    suffixStyle: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
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
                        color: Color(0xFFD32F2F),
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
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 13,
                      color: Colors.grey.shade500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isBuy
                          ? 'Exits when LTP ≤ stop-loss'
                          : 'Exits when LTP ≥ stop-loss',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Exit quantity',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                  decoration: InputDecoration(
                    suffixText: 'of ${order.quantity}',
                    suffixStyle: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
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
                        color: Color(0xFFD32F2F),
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext, {
                          'action': 'cancel',
                        }),
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
                        onPressed: () => Navigator.pop(dialogContext, {
                          'action': 'set',
                          'price': priceController.text.trim(),
                          'qty': qtyController.text.trim(),
                        }),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          _stopLossPrice > 0 ? 'Update' : 'Set stop-loss',
                          style: const TextStyle(
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
      ),
    );
    qtyController.dispose();

    if (result == null || !mounted) return;
    final action = result['action'] as String?;
    if (action == 'clear') {
      await _clearStopLoss();
      return;
    }
    if (action != 'set') return;

    final newPrice = double.tryParse(result['price'] as String? ?? '');
    final newQty = int.tryParse(result['qty'] as String? ?? '');
    if (newPrice == null || newPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid stop-loss price'),
          backgroundColor: Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (newQty == null || newQty < 1 || newQty > order.quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enter a quantity between 1 and ${order.quantity}'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await _applyStopLoss(newPrice, newQty);
  }

  Future<void> _applyStopLoss(double price, int qty) async {
    setState(() => _isSettingStopLoss = true);
    try {
      if (_stopLossPrice > 0) {
        await _repo.modifyStopLoss(
          widget.order.orderId,
          stopLossPrice: price,
          stopLossQty: qty,
        );
      } else {
        await _repo.setStopLossPrice(
          widget.order.orderId,
          stopLossPrice: price,
          stopLossQty: qty,
        );
      }
      if (!mounted) return;
      setState(() {
        _stopLossPrice = price;
        _stopLossQty = qty;
        _isSettingStopLoss = false;
      });
      widget.onClosed?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Stop-loss set at ₹${price.toStringAsFixed(2)} for ${widget.order.symbol}',
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade800
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSettingStopLoss = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to set stop-loss: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _clearStopLoss() async {
    setState(() => _isSettingStopLoss = true);
    try {
      await _repo.modifyStopLoss(widget.order.orderId, stopLossPrice: 0);
      if (!mounted) return;
      setState(() {
        _stopLossPrice = 0;
        _stopLossQty = 0;
        _isSettingStopLoss = false;
      });
      widget.onClosed?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Stop-loss cleared for ${widget.order.symbol}'),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade800
              : Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSettingStopLoss = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to clear stop-loss: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showModifyDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    setState(() => _isCancelling = true);
    Map<String, dynamic>? orderDetails;
    try {
      orderDetails = await _repo.fetchOrderDetail(widget.order.orderId);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _isCancelling = false);

    final limitPriceFromApi = orderDetails?['limit_price'];
    final ltpFromApi = orderDetails?['ltp'];

    final limitPrice = (limitPriceFromApi is num)
        ? limitPriceFromApi.toDouble()
        : widget.order.price > 0
        ? widget.order.price
        : 0.0;
    final ltp = (ltpFromApi is num) ? ltpFromApi.toDouble() : 0.0;

    _modifyPriceController = TextEditingController(
      text: limitPrice > 0 ? limitPrice.toStringAsFixed(2) : '',
    );
    final controller = _modifyPriceController!;

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
                  suffixText: ltp > 0
                      ? 'Market: ₹${ltp.toStringAsFixed(2)}'
                      : null,
                  suffixStyle: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
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

    final rawText = controller.text.trim();
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

    final isClosed =
        order.status == OrderStatus.closed ||
        order.status == OrderStatus.cancelled;

    final pnlPerUnit = isBuy
        ? _currentPrice - order.price
        : order.price - _currentPrice;
    final totalPnl = pnlPerUnit * order.quantity;
    final isProfit = (order.realisedPnl ?? totalPnl) >= 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────────
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

          // ── Detail rows ────────────────────────────────────────────────────
          _DetailRow(
            label: isClosed ? 'Trade price' : 'Entry price',
            value: '₹${order.price.toStringAsFixed(2)}',
          ),
          const SizedBox(height: 12),

          // Exit price from tradebook (closed orders)
          if (isClosed && order.exitPrice != null && order.exitPrice! > 0) ...[
            _DetailRow(
              label: 'Exit price',
              value: '₹${order.exitPrice!.toStringAsFixed(2)}',
            ),
            const SizedBox(height: 12),
          ],

          if (order.status == OrderStatus.open) ...[
            _DetailRow(
              label: 'Current price',
              value: _currentPrice > 0
                  ? '₹${_currentPrice.toStringAsFixed(2)}'
                  : '—',
            ),
            const SizedBox(height: 12),
          ],
          if (_contractInfo != null) ...[
            _DetailRow(
              label: 'Lot size',
              value: '${_contractInfo!.lotSize} qty',
            ),
            const SizedBox(height: 12),
          ],

          // Realised P&L for closed orders (from tradebook)
          if (isClosed && order.realisedPnl != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Realised P&L',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
                Text(
                  '${order.realisedPnl! >= 0 ? '+' : ''}₹${order.realisedPnl!.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isProfit
                        ? const Color(0xFF81C784)
                        : const Color(0xFFE57373),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],

          // Live P&L for open orders
          if (order.status == OrderStatus.open) ...[
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
                            '${totalPnl >= 0 ? '+' : ''}₹${totalPnl.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: totalPnl >= 0
                                  ? const Color(0xFF81C784)
                                  : const Color(0xFFE57373),
                            ),
                          ),
                          Text(
                            '${pnlPerUnit >= 0 ? '+' : ''}${order.price > 0 ? (pnlPerUnit / order.price * 100).toStringAsFixed(2) : '0.00'}%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: pnlPerUnit >= 0
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
            const SizedBox(height: 20),

            // Limit exit info box
            if (_exitLimitPrice > 0) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1B5E20).withValues(alpha: 0.2)
                      : const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.flag_rounded,
                      size: 16,
                      color: isDark
                          ? const Color(0xFF81C784)
                          : const Color(0xFF2E7D32),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Limit exit active · ₹${_exitLimitPrice.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFF81C784)
                                  : const Color(0xFF2E7D32),
                            ),
                          ),
                          if (_exitLimitQty > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Qty: $_exitLimitQty  ·  '
                              '${isBuy ? 'Triggers when LTP ≥ ₹${_exitLimitPrice.toStringAsFixed(2)}' : 'Triggers when LTP ≤ ₹${_exitLimitPrice.toStringAsFixed(2)}'}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? const Color(
                                        0xFF81C784,
                                      ).withValues(alpha: 0.7)
                                    : const Color(0xFF388E3C),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_stopLossPrice > 0) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFFB71C1C).withValues(alpha: 0.2)
                      : const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_rounded,
                      size: 16,
                      color: isDark
                          ? const Color(0xFFE57373)
                          : const Color(0xFFC62828),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Stop-loss active · ₹${_stopLossPrice.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFFE57373)
                                  : const Color(0xFFC62828),
                            ),
                          ),
                          if (_stopLossQty > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Qty: $_stopLossQty  ·  ${isBuy ? 'Triggers when LTP ≤ ₹${_stopLossPrice.toStringAsFixed(2)}' : 'Triggers when LTP ≥ ₹${_stopLossPrice.toStringAsFixed(2)}'}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? const Color(0xFFE57373).withValues(alpha: 0.7)
                                    : const Color(0xFFC62828),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],

          if (_contractLoading &&
              (order.status == OrderStatus.open ||
                  order.status == OrderStatus.pending)) ...[
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

          // ── OPEN order actions ─────────────────────────────────────────────
          if (order.status == OrderStatus.open) ...[
            const SizedBox(height: 8),
            if (_isSettingLimitExit)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _showLimitExitDialog,
                      icon: Icon(
                        _exitLimitPrice > 0
                            ? Icons.flag_rounded
                            : Icons.flag_outlined,
                        size: 16,
                        color: _exitLimitPrice > 0
                            ? const Color(0xFF388E3C)
                            : (isDark ? Colors.white70 : Colors.black87),
                      ),
                      label: Text(
                        _exitLimitPrice > 0
                            ? 'Edit target · ₹${_exitLimitPrice.toStringAsFixed(2)}'
                            : 'Set limit exit',
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: _exitLimitPrice > 0
                            ? const Color(0xFF388E3C)
                            : (isDark ? Colors.white70 : Colors.black87),
                        side: BorderSide(
                          color: _exitLimitPrice > 0
                              ? const Color(0xFF388E3C)
                              : (isDark ? Colors.white24 : Colors.grey.shade300),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isSettingStopLoss ? null : _showStopLossDialog,
                      icon: Icon(
                        _stopLossPrice > 0
                            ? Icons.shield_rounded
                            : Icons.shield_outlined,
                        size: 16,
                        color: _stopLossPrice > 0
                            ? const Color(0xFFC62828)
                            : (isDark ? Colors.white70 : Colors.black87),
                      ),
                      label: Text(
                        _stopLossPrice > 0
                            ? 'Edit stop-loss · ₹${_stopLossPrice.toStringAsFixed(2)}'
                            : 'Set stop-loss',
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: _stopLossPrice > 0
                            ? const Color(0xFFC62828)
                            : (isDark ? Colors.white70 : Colors.black87),
                        side: BorderSide(
                          color: _stopLossPrice > 0
                              ? const Color(0xFFC62828)
                              : (isDark ? Colors.white24 : Colors.grey.shade300),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
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

          // ── PENDING order actions ──────────────────────────────────────────
          if (order.status == OrderStatus.pending) ...[
            const SizedBox(height: 20),
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

// ─── _LimitOrderDetailSheet ───────────────────────────────────────────────────

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
  Map<String, dynamic>? _orderDetails;

  TextEditingController? _modifyPriceController;

  Future<void> _loadOrderDetails() async {
    try {
      final details = await _repo.fetchOrderDetail(widget.order.orderId);
      if (mounted) setState(() => _orderDetails = details);
    } catch (_) {}
  }

  Future<void> _showModifyDialog() async {
    await _loadOrderDetails();
    if (!mounted) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final limitPriceFromApi = _orderDetails?['limit_price'];
    final ltpFromApi = _orderDetails?['ltp'];

    final limitPrice = (limitPriceFromApi is num)
        ? limitPriceFromApi.toDouble()
        : widget.order.limitPrice;
    final ltp = (ltpFromApi is num) ? ltpFromApi.toDouble() : 0.0;

    _modifyPriceController = TextEditingController(
      text: limitPrice.toStringAsFixed(2),
    );
    final controller = _modifyPriceController!;

    final result = await showDialog<Map<String, dynamic>>(
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
                  suffixText: ltp > 0
                      ? 'Market: ₹${ltp.toStringAsFixed(2)}'
                      : null,
                  suffixStyle: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
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
                      onPressed: () => Navigator.pop(dialogContext, {
                        'confirmed': false,
                        'price': '',
                      }),
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
                      onPressed: () => Navigator.pop(dialogContext, {
                        'confirmed': true,
                        'price': controller.text.trim(),
                      }),
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

    controller.dispose();

    if (result?['confirmed'] != true || !mounted) return;

    final newPrice = double.tryParse(result!['price'] as String? ?? '');
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

    if (confirmed == true) await _cancelOrder();
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

// ─── Combined pending item ────────────────────────────────────────────────────

sealed class _PendingItem {}

class _PendingOrder extends _PendingItem {
  final Order order;
  _PendingOrder(this.order);
}

class _PendingLimit extends _PendingItem {
  final LimitOrder order;
  _PendingLimit(this.order);
}

// ─── Screen ───────────────────────────────────────────────────────────────────

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

  late Future<OrdersScreenData> _dataFuture;

  final Map<String, double> _ltpMap = {};
  StreamSubscription<Map<String, double>>? _ltpSub;

  String get _userId => ref.read(authProvider.notifier).userId ?? 'unknown';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _dataFuture = _repo.fetchAll(_userId);

    _pnlWs.connect(_userId);
    _ltpSub = _pnlWs.ltpStream.listen((ltpMap) {
      if (mounted) setState(() => _ltpMap.addAll(ltpMap));
    });
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
      _dataFuture = _repo.fetchAll(_userId);
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
      child: FutureBuilder<OrdersScreenData>(
        future: _dataFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snap.hasError) {
            return _buildError(isDark, snap.error.toString(), _refresh);
          }

          final data = snap.data!;
          final allOrders = _withLivePrices(data.orders);
          final limitOrders = data.limitOrders;

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
                    _buildOrderList(isDark: isDark, orders: allOrders),
                    _buildPendingTab(
                      isDark: isDark,
                      orders: allOrders
                          .where((o) => o.status == OrderStatus.pending)
                          .toList(),
                      limitOrders: limitOrders,
                    ),
                    _buildOrderList(
                      isDark: isDark,
                      orders: allOrders
                          .where((o) => o.status == OrderStatus.open)
                          .toList(),
                    ),
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
      ),
    );
  }

  Widget _buildOrderList({required bool isDark, required List<Order> orders}) {
    if (orders.isEmpty) return _emptyState(isDark);
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 100,
        ),
        itemCount: orders.length,
        separatorBuilder: (_, __) => Divider(
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
  }) {
    final items = <_PendingItem>[
      ...limitOrders.map(_PendingLimit.new),
      ...orders.map(_PendingOrder.new),
    ];

    if (items.isEmpty) return _emptyState(isDark);

    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 100,
        ),
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 1,
          color: isDark ? Colors.white10 : Colors.grey.shade100,
          indent: 16,
          endIndent: 16,
        ),
        itemBuilder: (context, index) {
          final item = items[index];
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

// ─── Order tile ───────────────────────────────────────────────────────────────

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

    // For closed orders prefer tradebook realised P&L
    final displayPnl = order.realisedPnl ?? totalPnl;
    final isProfit = displayPnl >= 0;

    final isClosed = order.status == OrderStatus.closed;

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
                  Row(
                    children: [
                      Text(
                        order.symbol,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      if (order.status == OrderStatus.open &&
                          (order.hasLimitExit || order.hasStopLoss)) ...[
                        const SizedBox(width: 6),
                        Icon(
                          order.hasStopLoss && !order.hasLimitExit
                              ? Icons.shield_rounded
                              : Icons.flag_rounded,
                          size: 13,
                          color: order.hasStopLoss && !order.hasLimitExit
                              ? (isDark
                                    ? const Color(0xFFE57373)
                                    : const Color(0xFFC62828))
                              : (isDark
                                    ? const Color(0xFF81C784)
                                    : const Color(0xFF2E7D32)),
                        ),
                      ],
                    ],
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
                        order.status == OrderStatus.pending &&
                                order.limitPrice > 0
                            ? '${order.quantity} qty  ·  limit ₹${order.limitPrice.toStringAsFixed(2)}'
                            : order.status == OrderStatus.open &&
                                  order.price > 0
                            ? '${order.quantity} qty  ·  avg ₹${order.price.toStringAsFixed(2)}'
                            : '${order.quantity} qty',
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
                // Closed: show realised P&L from tradebook
                if (isClosed && order.realisedPnl != null)
                  Text(
                    '${isProfit ? '+' : ''}₹${order.realisedPnl!.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isProfit
                          ? const Color(0xFF81C784)
                          : const Color(0xFFE57373),
                    ),
                  )
                // Open: show live P&L
                else if (order.status != OrderStatus.pending && hasLivePrice)
                  Text(
                    '${totalPnl >= 0 ? '+' : ''}₹${totalPnl.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: totalPnl >= 0
                          ? const Color(0xFF81C784)
                          : const Color(0xFFE57373),
                    ),
                  )
                else if (order.status != OrderStatus.pending)
                  Text(
                    '₹${order.totalValue.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Limit order tile ─────────────────────────────────────────────────────────

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
