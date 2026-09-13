import 'package:capit_n_bulls/index_detail_sheet.dart';
import 'package:capit_n_bulls/searchpage.dart';
import 'package:capit_n_bulls/providers/watchlist_provider.dart';
import 'package:capit_n_bulls/providers/live_stocks_provider.dart';
import 'package:capit_n_bulls/providers/live_indices_provider.dart';
import 'package:capit_n_bulls/orders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import './stock.dart';
import './index_card.dart';
import './stock_list_tile.dart';

// ── Server config ─────────────────────────────────────────────────────────────
const String kServerHost = '69.62.75.117';
const String kWsUrl = 'ws://$kServerHost:8765/ws/live-prices';
const String kNamesUrl = 'http://$kServerHost:8765/instruments/names';
// ─────────────────────────────────────────────────────────────────────────────

class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  final List<IndexData> _indices = [];

  final Map<int, ({String symbol, String exchange})> _tokenMeta = {};

  bool _awaitingFirstTick = true;

  static const bool _debug = true;
  String _debugMsg = 'Connecting…';
  bool _showDebugBanner = true;

  late WebSocketChannel _channel;
  StreamSubscription? _wsSubscription;
  Timer? _bannerTimer;
  bool _isDisposing = false;

  @override
  void initState() {
    super.initState();
    _fetchInstrumentNames();
    _connectWebSocket();
  }

  Future<void> _fetchInstrumentNames() async {
    try {
      final res = await http
          .get(Uri.parse(kNamesUrl))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(res.body) as Map<String, dynamic>;
        body.forEach((key, value) {
          final token = int.tryParse(key);
          if (token != null && value is Map<String, dynamic>) {
            _tokenMeta[token] = (
              symbol: (value['symbol'] as String? ?? key),
              exchange: (value['exchange'] as String? ?? 'NSE'),
            );
          }
        });
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted || _isDisposing) return;
    setState(fn);
  }

  String _getMonthCode(int month) {
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return months[month - 1];
  }

  void _connectWebSocket() {
    _channel = WebSocketChannel.connect(Uri.parse(kWsUrl));
    _wsSubscription = _channel.stream.listen(
      _onMessage,
      onError: (e) {
        debugPrint('WS error: $e');
        _safeSetState(() => _debugMsg = 'WS error: $e');
      },
      onDone: () {
        debugPrint('WS closed');
        if (_isDisposing) return;
        _safeSetState(() => _debugMsg = 'WS closed');
      },
      cancelOnError: true,
    );
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      if (mounted) setState(() => _debugMsg = 'JSON parse error: $e');
      return;
    }

    final priceFeed = decoded['price_feed'];
    if (priceFeed is! Map<String, dynamic>) {
      if (mounted) {
        setState(
          () => _debugMsg = 'No price_feed. Keys: ${decoded.keys.toList()}',
        );
      }
      return;
    }

    // ── Extract NIFTY / BANKNIFTY by key prefix matching ─────────────────
    // Keys in price_feed look like "BANKNIFTY26MAYFUT", "NIFTY26MAYFUT" etc.
    // We check BANKNIFTY first (more specific) so it doesn't get caught by
    // the NIFTY check. Only match futures contracts (ending with FUT).
    // Also filter to current and next month futures.
    final now = DateTime.now();
    final currentMonthCode = _getMonthCode(now.month);
    final nextMonth = now.month == 12 ? 1 : now.month + 1;
    final nextMonthCode = _getMonthCode(nextMonth);

    for (final entry in priceFeed.entries) {
      final key = entry.key;
      if (entry.value is! Map<String, dynamic>) continue;
      final feedEntry = entry.value as Map<String, dynamic>;

      String? matchedName;
      if (key.startsWith('BANKNIFTY') && key.endsWith('FUT')) {
        matchedName = key;
      } else if (key.startsWith('NIFTY') && key.endsWith('FUT')) {
        matchedName = key;
      }

      if (matchedName == null) continue;

      // Only add if it's the current or next month contract
      if (!matchedName.contains(currentMonthCode) &&
          !matchedName.contains(nextMonthCode)) {
        continue;
      }

      final ohlc = feedEntry['ohlc'] as Map<String, dynamic>? ?? {};
      final double lastPrice =
          (feedEntry['last_price'] as num?)?.toDouble() ?? 0.0;
      final double change = (feedEntry['change'] as num?)?.toDouble() ?? 0.0;
      final double open = (ohlc['open'] as num?)?.toDouble() ?? 0.0;
      final double high = (ohlc['high'] as num?)?.toDouble() ?? 0.0;
      final double low = (ohlc['low'] as num?)?.toDouble() ?? 0.0;
      final double prevClose = (ohlc['close'] as num?)?.toDouble() ?? 0.0;

      final indexData = IndexData(
        name: matchedName,
        value: lastPrice.toStringAsFixed(2),
        change: '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
        isPositive: change >= 0,
        open: open.toStringAsFixed(2),
        high: high.toStringAsFixed(2),
        low: low.toStringAsFixed(2),
        prevClose: prevClose.toStringAsFixed(2),
      );

      final existingIdx = _indices.indexWhere((i) => i.name == matchedName);
      if (existingIdx == -1) {
        _indices.add(indexData);
      } else {
        _indices[existingIdx] = indexData;
      }
    }

    // ── Collect all stock updates into a batch ────────────────────────────
    final Map<int, StockData> batch = {};
    final stockNotifier = ref.read(liveStocksProvider.notifier);
    final currentStockMap = ref.read(liveStocksProvider);

    // ── Also prepare index updates ──────────────────────────────────────────
    final Map<String, IndexData> indexBatch = {};
    final indexNotifier = ref.read(liveIndicesProvider.notifier);
    for (final idx in _indices) {
      indexBatch[idx.name] = idx;
    }

    bool didChange = false;

    for (final entry in priceFeed.entries) {
      final key = entry.key;

      // Skip index futures — already handled above
      if (key.startsWith('BANKNIFTY') || key.startsWith('NIFTY')) continue;

      if (entry.value is! Map<String, dynamic>) continue;
      final feedEntry = entry.value as Map<String, dynamic>;

      final tokenFromFeed = feedEntry['instrument_token'];
      final int token;
      if (tokenFromFeed is int) {
        token = tokenFromFeed;
      } else if (tokenFromFeed is double) {
        token = tokenFromFeed.toInt();
      } else {
        token = entry.key.hashCode;
      }

      // Register the contract name → numeric token mapping for orders screen
      if (tokenFromFeed is int || tokenFromFeed is double) {
        ContractTokenRegistry.registerContract(key, token);
      }

      final symbol = _tokenMeta[token]?.symbol ?? entry.key;
      const exchange = 'NSE';

      _tokenMeta.putIfAbsent(token, () => (symbol: symbol, exchange: exchange));

      final prev = currentStockMap[token];
      final stockData = StockData.fromWsFeed(
        token: token,
        map: feedEntry,
        symbol: symbol,
        exchange: exchange,
        prevUpperCircuit: prev?.upperCircuit,
        prevLowerCircuit: prev?.lowerCircuit,
        prevWeek52High: prev?.week52High,
        prevWeek52Low: prev?.week52Low,
        companyName: prev?.companyName,
      );
      batch[token] = stockData;

      didChange = true;
    }

    // ── Push the whole batch to the provider in one shot ─────────────────
    if (batch.isNotEmpty) {
      stockNotifier.updateBatch(batch);
    }
    if (indexBatch.isNotEmpty) {
      indexNotifier.updateBatch(indexBatch);
    }

    if (!mounted) return;
    if (didChange) {
      final stockCount = currentStockMap.length + batch.length;
      final wasAwaiting = _awaitingFirstTick;
      setState(() {
        _awaitingFirstTick = false;
        _debugMsg = '✅ Live | $stockCount stocks | ${_indices.length} indices';
      });
      if (wasAwaiting) {
        _bannerTimer?.cancel();
        _bannerTimer = Timer(const Duration(seconds: 5), () {
          _safeSetState(() => _showDebugBanner = false);
        });
      }
    }
  }

  void _openSearch() {
    final allStocks = ref.read(liveStocksProvider).values.toList();
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, _, _) =>
                SearchPage(stocks: allStocks, indices: _indices),
            transitionsBuilder: (_, animation, _, child) {
              final tween = Tween(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeOutCubic));
              return SlideTransition(
                position: animation.drive(tween),
                child: child,
              );
            },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  @override
  void dispose() {
    _isDisposing = true;
    _bannerTimer?.cancel();
    _wsSubscription?.cancel();
    _channel.sink.close(1000, 'Navigating away');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watchlistAsync = ref.watch(watchlistProvider);
    final watchlistSymbols = watchlistAsync.value ?? {};

    final stockMap = ref.watch(liveStocksProvider);
    final watchedStocks = stockMap.values
        .where((s) => watchlistSymbols.contains(s.symbol))
        .toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stripBg = isDark ? const Color(0xFF1A1A1A) : Colors.grey.shade200;
    final searchBg = isDark ? const Color(0xFF272727) : Colors.black;
    final searchBorder = isDark ? const Color(0xFF272727) : Colors.transparent;

    return Column(
      children: [
        // ── Debug banner ───────────────────────────────────────────────────
        if (_debug && _showDebugBanner)
          Material(
            color: _awaitingFirstTick
                ? Colors.orange.shade900
                : Colors.green.shade900,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Row(
                children: [
                  Icon(
                    _awaitingFirstTick ? Icons.hourglass_top : Icons.wifi,
                    color: Colors.white,
                    size: 13,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _debugMsg,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ── Index strip + search bar ───────────────────────────────────────
        Container(
          color: stripBg,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            children: [
              if (_indices.isNotEmpty) ...[
                Row(
                  children: _indices
                      .where((idx) {
                        final now = DateTime.now();
                        final currentMonthCode = _getMonthCode(now.month);
                        return idx.name.contains(currentMonthCode);
                      })
                      .map(
                        (idx) => IndexCard(
                          data: idx,
                          onTap: () => IndexDetailSheet.show(context, idx),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
              ],
              GestureDetector(
                onTap: _openSearch,
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: searchBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: searchBorder, width: 0.5),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Search',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.search, color: Colors.white, size: 22),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Watchlist stock list ───────────────────────────────────────────
        Expanded(
          child: _awaitingFirstTick
              ? const Center(child: CircularProgressIndicator())
              : watchedStocks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bookmark_border,
                        size: 48,
                        color: isDark ? Colors.white24 : Colors.black26,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Your watchlist is empty',
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Search for stocks and tap + to add them',
                        style: TextStyle(
                          color: isDark ? Colors.white24 : Colors.black26,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: watchedStocks.length,
                  itemBuilder: (_, i) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StockListTile(stock: watchedStocks[i]),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
