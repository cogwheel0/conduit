import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/webview_cookie_helper.dart';
import '../../core/utils/debug_logger.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import 'chatgpt_providers.dart';

Uri? validateChatGptVerificationUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'auth.openai.com' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    return null;
  }
  return uri;
}

bool isAllowedChatGptBrowserNavigation(Uri uri) {
  if (uri.scheme == 'about' && uri.toString() == 'about:blank') return true;
  return uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.port == 443;
}

class ChatGptVerificationBrowser extends ConsumerStatefulWidget {
  const ChatGptVerificationBrowser({
    required this.initialUrl,
    required this.userCode,
    super.key,
  });

  final Uri initialUrl;
  final String userCode;

  @override
  ConsumerState<ChatGptVerificationBrowser> createState() =>
      _ChatGptVerificationBrowserState();
}

class _ChatGptVerificationBrowserState
    extends ConsumerState<ChatGptVerificationBrowser> {
  bool _webViewReady = false;
  bool _loading = true;
  bool _loadFailed = false;
  bool _dismissScheduled = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareWebView());
  }

  Future<void> _prepareWebView() async {
    try {
      await WebViewCookieHelper.waitForPendingDataOperations().timeout(
        const Duration(seconds: 10),
      );
    } catch (error) {
      DebugLogger.error(
        'verification-cookie-wait-failed',
        scope: 'auth/chatgpt',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    if (!mounted) return;
    setState(() => _webViewReady = true);
  }

  void _dismissAfterAuthentication(ChatGptConnectionState? connection) {
    if (_dismissScheduled ||
        connection?.status != ChatGptConnectionStatus.authenticated) {
      return;
    }
    _dismissScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(Navigator.of(context).maybePop());
    });
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.userCode));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.codeCopiedToClipboard)));
  }

  NavigationActionPolicy _navigationPolicy(NavigationAction action) {
    final rawUrl = action.request.url?.toString();
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri != null && isAllowedChatGptBrowserNavigation(uri)) {
      return NavigationActionPolicy.ALLOW;
    }
    DebugLogger.error(
      'verification-navigation-rejected',
      scope: 'auth/chatgpt',
      data: {'scheme': uri?.scheme ?? 'invalid'},
    );
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    _dismissAfterAuthentication(ref.watch(chatGptConnectionProvider).value);
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Scaffold(
      key: const ValueKey<String>('chatgpt-verification-browser'),
      backgroundColor: theme.surfaceBackground,
      appBar: AppBar(title: Text(l10n.chatGptAccountTitle)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: theme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.chatGptDeviceCodeInstructions,
                          style: theme.bodySmall?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        SelectableText(
                          widget.userCode,
                          style: theme.headingMedium?.copyWith(
                            color: theme.textPrimary,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.copy,
                    onPressed: _copyCode,
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
            ),
          ),
          if (_loading && _webViewReady && isWebViewSupported)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          Expanded(child: _buildBrowser(l10n)),
        ],
      ),
    );
  }

  Widget _buildBrowser(AppLocalizations l10n) {
    if (!isWebViewSupported) {
      return Center(child: Text(l10n.chatGptLoginError));
    }
    if (!_webViewReady) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_loadFailed) {
      return Center(child: Text(l10n.chatGptLoginError));
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
        useShouldOverrideUrlLoading: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
      ),
      shouldOverrideUrlLoading: (controller, action) async =>
          _navigationPolicy(action),
      onProgressChanged: (controller, progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress / 100;
          _loading = progress < 100;
        });
      },
      onLoadStart: (controller, url) {
        if (!mounted) return;
        setState(() {
          _loadFailed = false;
          _loading = true;
        });
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != true || !mounted) return;
        DebugLogger.error(
          'verification-page-load-failed',
          scope: 'auth/chatgpt',
          data: {'errorType': error.type.toString()},
        );
        setState(() {
          _loadFailed = true;
          _loading = false;
        });
      },
    );
  }
}
