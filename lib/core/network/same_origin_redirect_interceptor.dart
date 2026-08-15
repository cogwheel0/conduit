import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

const _redirectStatusCodes = {
  HttpStatus.movedPermanently,
  HttpStatus.found,
  HttpStatus.seeOther,
  HttpStatus.temporaryRedirect,
  HttpStatus.permanentRedirect,
};
const _maximumHops = 5;
const _hopExtraKey = 'conduit.sameOriginRedirectHops';

int _effectiveHttpPort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
}

/// Whether a redirect target may retain credentials from the current request.
bool isCredentialSafeRedirectTarget(Uri from, Uri to) {
  final fromScheme = from.scheme.toLowerCase();
  final toScheme = to.scheme.toLowerCase();
  if (toScheme != 'http' && toScheme != 'https') return false;
  if (to.host.isEmpty || to.host.toLowerCase() != from.host.toLowerCase()) {
    return false;
  }
  if (toScheme == fromScheme) {
    return _effectiveHttpPort(to) == _effectiveHttpPort(from);
  }
  return fromScheme == 'http' &&
      toScheme == 'https' &&
      _effectiveHttpPort(from) == 80 &&
      _effectiveHttpPort(to) == 443;
}

@visibleForTesting
RequestOptions? nextSameOriginRedirectRequest({
  required RequestOptions options,
  required Response<dynamic> response,
}) {
  final status = response.statusCode;
  if (status == null || !_redirectStatusCodes.contains(status)) return null;

  final method = options.method.toUpperCase();
  final convertsToGet = status == HttpStatus.seeOther && method != 'HEAD';
  if (method != 'GET' && method != 'HEAD' && !convertsToGet) return null;

  final locationValue = response.headers.value(HttpHeaders.locationHeader);
  final location = locationValue == null ? null : Uri.tryParse(locationValue);
  if (location == null) return null;
  final target = options.uri.resolveUri(location);
  final hops = (options.extra[_hopExtraKey] as int?) ?? 0;
  if (hops >= _maximumHops ||
      !isCredentialSafeRedirectTarget(options.uri, target)) {
    return null;
  }

  final redirected = options.copyWith(
    path: target.toString(),
    queryParameters: const <String, dynamic>{},
    extra: Map<String, dynamic>.of(options.extra)..[_hopExtraKey] = hops + 1,
    headers: Map<String, dynamic>.of(options.headers),
  );
  if (convertsToGet) {
    redirected.method = 'GET';
    redirected.data = null;
    redirected.headers.removeWhere((name, _) {
      final normalized = name.toLowerCase();
      return normalized == Headers.contentLengthHeader ||
          normalized == Headers.contentTypeHeader;
    });
  }
  return redirected;
}

/// Replays only credential-safe, idempotent redirects surfaced by Dio.
final class SameOriginRedirectInterceptor extends Interceptor {
  SameOriginRedirectInterceptor(this.dio, {required this.prepareReplay});

  final Dio dio;
  final void Function(RequestOptions options) prepareReplay;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    final redirectedOptions = response == null
        ? null
        : nextSameOriginRedirectRequest(
            options: err.requestOptions,
            response: response,
          );
    if (err.type != DioExceptionType.badResponse || redirectedOptions == null) {
      return handler.next(err);
    }
    prepareReplay(redirectedOptions);
    try {
      handler.resolve(await dio.fetch<dynamic>(redirectedOptions));
    } on DioException catch (redirectError) {
      handler.next(redirectError);
    }
  }
}
