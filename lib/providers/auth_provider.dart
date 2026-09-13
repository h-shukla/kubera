import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _kAccessTokenKey = 'access_token';
const _kRefreshTokenKey = 'refresh_token';
const _kUserIdKey = 'user_id';
const _kUsernameKey = 'username';
const _kEmailKey = 'email';

enum AuthStatus { loading, authenticated, unauthenticated }

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthStatus>(
  AuthNotifier.new,
);

class AuthNotifier extends AsyncNotifier<AuthStatus> {
  late SharedPreferences _prefs;

  String? accessToken;
  String? refreshToken;
  String? userId;
  String? username; // ← new
  String? email; // ← new

  @override
  Future<AuthStatus> build() async {
    _prefs = await SharedPreferences.getInstance();

    accessToken = _prefs.getString(_kAccessTokenKey);
    refreshToken = _prefs.getString(_kRefreshTokenKey);
    userId = _prefs.getString(_kUserIdKey);
    username = _prefs.getString(_kUsernameKey); // ← restored on cold start
    email = _prefs.getString(_kEmailKey); // ← restored on cold start

    if (accessToken != null && refreshToken != null) {
      return AuthStatus.authenticated;
    }
    return AuthStatus.unauthenticated;
  }

  Future<void> login({required String email, required String password}) async {
    state = const AsyncLoading();
    try {
      final response = await http.post(
        Uri.parse('http://69.62.75.117:8000/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      print('Login response: $data');
      if (response.statusCode == 200) {
        await _saveTokens(data);
        state = const AsyncData(AuthStatus.authenticated);
      } else {
        state = AsyncError(
          data['detail'] ?? 'Login failed',
          StackTrace.current,
        );
      }
    } catch (e, st) {
      state = AsyncError('Network error', st);
    }
  }

  Future<void> signup({
    required String email,
    required String password,
    required String confirmPassword,
  }) async {
    state = const AsyncLoading();
    try {
      final response = await http.post(
        Uri.parse('http://69.62.75.117:8000/auth/signup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'confirm_password': confirmPassword,
        }),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 || response.statusCode == 201) {
        await _saveTokens(data);
        state = const AsyncData(AuthStatus.authenticated);
      } else {
        state = AsyncError(
          data['detail'] ?? 'Signup failed',
          StackTrace.current,
        );
      }
    } catch (e, st) {
      state = AsyncError('Network error', st);
    }
  }

  Future<void> logout() async {
    // Optionally hit POST /auth/logout (fire-and-forget — JWT is stateless)
    if (accessToken != null) {
      http
          .post(
            Uri.parse('http://69.62.75.117:8000/auth/logout'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
          )
          .ignore();
    }

    await _prefs.remove(_kAccessTokenKey);
    await _prefs.remove(_kRefreshTokenKey);
    await _prefs.remove(_kUserIdKey);
    await _prefs.remove(_kUsernameKey);
    await _prefs.remove(_kEmailKey);

    accessToken = null;
    refreshToken = null;
    userId = null;
    username = null;
    email = null;

    state = const AsyncData(AuthStatus.unauthenticated);
  }

  // ── Token refresh ────────────────────────────────────────────────────────
  /// Call this from an HTTP interceptor or before any authenticated request
  /// when you get a 401. Returns true if refresh succeeded.
  Future<bool> tryRefresh() async {
    if (refreshToken == null) return false;
    try {
      final response = await http.post(
        Uri.parse('http://69.62.75.117:8000/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        await _saveTokens(data);
        return true;
      }
    } catch (_) {}
    // Refresh failed — force logout
    await logout();
    return false;
  }

  // ── Internal ─────────────────────────────────────────────────────────────
  Future<void> _saveTokens(Map<String, dynamic> data) async {
    accessToken = data['access_token'] as String?;
    refreshToken = data['refresh_token'] as String?;
    userId = data['user_id'] as String?;
    username = data['username'] as String?;
    email = data['email'] as String?;

    if (accessToken != null) {
      await _prefs.setString(_kAccessTokenKey, accessToken!);
    }
    if (refreshToken != null) {
      await _prefs.setString(_kRefreshTokenKey, refreshToken!);
    }
    if (userId != null) await _prefs.setString(_kUserIdKey, userId!);
    if (username != null) await _prefs.setString(_kUsernameKey, username!);
    if (email != null) await _prefs.setString(_kEmailKey, email!);
  }
}
