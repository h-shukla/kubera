import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'auth_provider.dart';

const String _kServerHost = '69.62.75.117';
const String _kWatchlistBaseUrl = 'http://$_kServerHost:8000/watchlist';

class WatchlistNotifier extends AsyncNotifier<Set<String>> {
  late String _userId;

  @override
  Future<Set<String>> build() async {
    final authNotifier = ref.read(authProvider.notifier);
    _userId = authNotifier.userId ?? '';

    if (_userId.isEmpty) {
      return {};
    }

    return _fetchWatchlist();
  }

  Future<Set<String>> _fetchWatchlist() async {
    try {
      final response = await http.get(
        Uri.parse('$_kWatchlistBaseUrl/$_userId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final stocks = data['stocks'] as List<dynamic>? ?? [];
        final symbols = stocks
            .whereType<Map<String, dynamic>>()
            .map((s) => (s['symbol'] as String? ?? '').toUpperCase())
            .where((s) => s.isNotEmpty)
            .toSet();
        return symbols;
      } else if (response.statusCode == 404) {
        // User not found, return empty watchlist
        return {};
      }
      return state.value ?? {};
    } catch (e) {
      debugPrint('Error fetching watchlist: $e');
      return state.value ?? {};
    }
  }

  Future<void> add(String symbol) async {
    if (_userId.isEmpty) return;

    final current = state.value ?? {};
    if (current.contains(symbol.toUpperCase())) return;

    // Optimistic update
    final updated = {...current, symbol.toUpperCase()};
    state = AsyncData(updated);

    try {
      final response = await http.post(
        Uri.parse('$_kWatchlistBaseUrl/$_userId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'symbol': symbol.toUpperCase()}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Keep the optimistic update
      } else if (response.statusCode == 409) {
        // Already in watchlist, revert to current
        state = AsyncData(current);
      } else {
        // On error, revert
        state = AsyncData(current);
      }
    } catch (e) {
      debugPrint('Error adding to watchlist: $e');
      state = AsyncData(current);
    }
  }

  Future<void> remove(String symbol) async {
    if (_userId.isEmpty) return;

    final current = state.value ?? {};
    final upperSymbol = symbol.toUpperCase();

    // Optimistic update
    final updated = {...current}..remove(upperSymbol);
    state = AsyncData(updated);

    try {
      final response = await http.delete(
        Uri.parse('$_kWatchlistBaseUrl/$_userId/$upperSymbol'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        // Keep the optimistic update
      } else {
        // On error, revert
        state = AsyncData(current);
      }
    } catch (e) {
      debugPrint('Error removing from watchlist: $e');
      state = AsyncData(current);
    }
  }

  bool contains(String symbol) =>
      state.value?.contains(symbol.toUpperCase()) ?? false;

  Future<void> refresh() async {
    if (_userId.isNotEmpty) {
      state = const AsyncLoading();
      state = AsyncData(await _fetchWatchlist());
    }
  }
}

final watchlistProvider = AsyncNotifierProvider<WatchlistNotifier, Set<String>>(
  WatchlistNotifier.new,
);
