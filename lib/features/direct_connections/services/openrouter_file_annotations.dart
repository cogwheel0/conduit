import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/direct_completion.dart';
import '../models/direct_connection_profile.dart';

const String kOpenRouterFileAnnotationsMetadataKey =
    'openrouterFileAnnotationsV1';
const String _profileBindingDomain =
    'conduit-openrouter-file-annotations-profile-v1';
const String _signatureDomain = 'conduit-openrouter-file-annotations-v3';
const int kOpenRouterMaxFileAnnotations = 4;
const int kOpenRouterMaxAnnotationContentParts = 256;
const int kOpenRouterMaxAnnotationTextCharacters = 2 * 1024 * 1024;
const int _kOpenRouterMaxAnnotationCandidates = 256;
const int _kOpenRouterMaxAttachmentIdCharacters = 512;

final class TrustedOpenRouterFileAnnotationEnvelope {
  const TrustedOpenRouterFileAnnotationEnvelope({
    required this.annotations,
    required this.attachmentIds,
  });

  final List<Map<String, dynamic>> annotations;
  final Set<String> attachmentIds;
}

/// Extracts the success- and error-path PDF annotations documented by
/// OpenRouter, discarding malformed or unbounded content.
List<Map<String, dynamic>> openRouterFileAnnotationsFromPayload(
  Map<String, dynamic> payload,
) {
  final candidates = <Object?>[];
  void addCandidates(Iterable rawCandidates) {
    for (final candidate in rawCandidates) {
      if (candidates.length >= _kOpenRouterMaxAnnotationCandidates) return;
      candidates.add(candidate);
    }
  }

  final choices = payload['choices'];
  if (choices is Iterable) {
    for (final choice in choices) {
      if (choice is! Map) continue;
      final message = choice['message'] ?? choice['delta'];
      if (message is Map && message['annotations'] is Iterable) {
        addCandidates(message['annotations'] as Iterable);
      }
    }
  }
  final error = payload['error'];
  if (error is Map) {
    final metadata = error['metadata'];
    if (metadata is Map && metadata['file_annotations'] is Iterable) {
      addCandidates(metadata['file_annotations'] as Iterable);
    }
  }
  return normalizeOpenRouterFileAnnotations(candidates);
}

List<Map<String, dynamic>> normalizeOpenRouterFileAnnotations(Object? value) {
  if (value is! Iterable) return const <Map<String, dynamic>>[];
  final result = <Map<String, dynamic>>[];
  final seenHashes = <String>{};
  var totalCharacters = 0;

  for (final raw in value) {
    if (result.length >= kOpenRouterMaxFileAnnotations || raw is! Map) break;
    if (raw['type'] != 'file') continue;
    final rawFile = raw['file'];
    if (rawFile is! Map) continue;
    final hash = rawFile['hash']?.toString().trim() ?? '';
    if (hash.isEmpty ||
        hash.length > 512 ||
        hash.contains(RegExp(r'[\r\n\u0000]')) ||
        !seenHashes.add(hash)) {
      continue;
    }
    final rawName = rawFile['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : null;
    if (name != null &&
        (name.length > 240 || name.contains(RegExp(r'[\r\n\u0000]')))) {
      continue;
    }
    final rawContent = rawFile['content'];
    if (rawContent is! Iterable) continue;
    final content = <Map<String, dynamic>>[];
    var valid = true;
    for (final rawPart in rawContent) {
      if (content.length >= kOpenRouterMaxAnnotationContentParts ||
          rawPart is! Map ||
          rawPart['type'] != 'text' ||
          rawPart['text'] is! String) {
        valid = false;
        break;
      }
      final text = rawPart['text'] as String;
      totalCharacters += text.length;
      if (totalCharacters > kOpenRouterMaxAnnotationTextCharacters) {
        valid = false;
        break;
      }
      content.add(<String, dynamic>{'type': 'text', 'text': text});
    }
    if (!valid || content.isEmpty) continue;
    result.add(<String, dynamic>{
      'type': 'file',
      'file': <String, dynamic>{
        'hash': hash,
        'name': ?name,
        'content': content,
      },
    });
  }
  return List<Map<String, dynamic>>.unmodifiable(result);
}

Map<String, dynamic> signedOpenRouterFileAnnotations({
  required Iterable<Map<String, dynamic>> annotations,
  required List<int> signingKey,
  required DirectConnectionProfile profile,
  Iterable<String> attachmentIds = const <String>[],
}) {
  if (signingKey.isEmpty) {
    throw ArgumentError.value(signingKey, 'signingKey', 'must not be empty');
  }
  if (!profile.isOpenRouter) {
    throw ArgumentError.value(
      profile.id,
      'profile',
      'must be an OpenRouter profile',
    );
  }
  final normalized = normalizeOpenRouterFileAnnotations(annotations);
  final normalizedAttachmentIds = _normalizeAttachmentIds(attachmentIds);
  final profileBinding = _profileBinding(profile, signingKey);
  final signature = _signatureFor(
    normalized,
    normalizedAttachmentIds,
    profileBinding,
    signingKey,
  );
  return <String, dynamic>{
    'annotations': normalized,
    if (normalizedAttachmentIds.isNotEmpty)
      'attachmentIds': normalizedAttachmentIds,
    'profileBinding': profileBinding,
    'signature': signature,
  };
}

List<Map<String, dynamic>> trustedOpenRouterFileAnnotations(
  Object? envelope, {
  required List<int> verificationKey,
  required DirectConnectionProfile profile,
}) => trustedOpenRouterFileAnnotationEnvelope(
  envelope,
  verificationKey: verificationKey,
  profile: profile,
).annotations;

TrustedOpenRouterFileAnnotationEnvelope trustedOpenRouterFileAnnotationEnvelope(
  Object? envelope, {
  required List<int> verificationKey,
  required DirectConnectionProfile profile,
}) {
  const empty = TrustedOpenRouterFileAnnotationEnvelope(
    annotations: <Map<String, dynamic>>[],
    attachmentIds: <String>{},
  );
  if (verificationKey.isEmpty || !profile.isOpenRouter || envelope is! Map) {
    return empty;
  }
  final signature = envelope['signature'];
  final profileBinding = envelope['profileBinding'];
  if (signature is! String ||
      signature.length != 43 ||
      profileBinding is! String ||
      profileBinding.length != 43) {
    return empty;
  }
  final expectedProfileBinding = _profileBinding(profile, verificationKey);
  if (!_constantTimeEquals(profileBinding, expectedProfileBinding)) {
    return empty;
  }
  final normalized = normalizeOpenRouterFileAnnotations(
    envelope['annotations'],
  );
  if (normalized.isEmpty) return empty;
  final normalizedAttachmentIds = _normalizeAttachmentIds(
    envelope['attachmentIds'],
  );
  if (envelope.containsKey('attachmentIds') &&
      normalizedAttachmentIds.isEmpty) {
    return empty;
  }
  final expected = _signatureFor(
    normalized,
    normalizedAttachmentIds,
    profileBinding,
    verificationKey,
  );
  if (!_constantTimeEquals(signature, expected)) return empty;
  return TrustedOpenRouterFileAnnotationEnvelope(
    annotations: normalized,
    attachmentIds: Set<String>.unmodifiable(normalizedAttachmentIds),
  );
}

List<String> openRouterPdfAttachmentIdsForAnnotations({
  required Map<String, DirectFilePart> ephemeralFilePartsByAttachmentId,
  required Iterable<Map<String, dynamic>> annotations,
}) {
  if (ephemeralFilePartsByAttachmentId.isEmpty) return const <String>[];
  final normalizedAnnotations = normalizeOpenRouterFileAnnotations(annotations);
  if (normalizedAnnotations.isEmpty) return const <String>[];

  final unmatchedByName = <String, List<String>>{};
  for (final entry in ephemeralFilePartsByAttachmentId.entries) {
    unmatchedByName
        .putIfAbsent(entry.value.filename, () => <String>[])
        .add(entry.key);
  }
  final matched = <String>[];
  for (final annotation in normalizedAnnotations) {
    final file = annotation['file'];
    final name = file is Map ? file['name'] : null;
    if (name is String) {
      final candidates = unmatchedByName[name];
      if (candidates != null && candidates.isNotEmpty) {
        matched.add(candidates.removeAt(0));
      }
    }
  }
  if (matched.isEmpty &&
      ephemeralFilePartsByAttachmentId.length == 1 &&
      normalizedAnnotations.length == 1 &&
      (normalizedAnnotations.single['file'] as Map)['name'] == null) {
    matched.add(ephemeralFilePartsByAttachmentId.keys.single);
  }
  return List<String>.unmodifiable(matched);
}

List<String> _normalizeAttachmentIds(Object? value) {
  if (value is! Iterable) return const <String>[];
  final result = <String>[];
  final seen = <String>{};
  for (final raw in value) {
    if (result.length >= kOpenRouterMaxFileAnnotations || raw is! String) {
      break;
    }
    final id = raw.trim();
    if (id.isEmpty ||
        id.length > _kOpenRouterMaxAttachmentIdCharacters ||
        id.contains(RegExp(r'[\r\n\u0000]')) ||
        !seen.add(id)) {
      continue;
    }
    result.add(id);
  }
  return List<String>.unmodifiable(result);
}

String _signatureFor(
  List<Map<String, dynamic>> annotations,
  List<String> attachmentIds,
  String profileBinding,
  List<int> key,
) {
  final canonical = jsonEncode(<Object>[
    _signatureDomain,
    profileBinding,
    annotations,
    attachmentIds,
  ]);
  return base64Url
      .encode(Hmac(sha256, key).convert(utf8.encode(canonical)).bytes)
      .replaceAll('=', '');
}

String _profileBinding(DirectConnectionProfile profile, List<int> key) {
  final sortedHeaders = profile.customHeaders.entries.toList(growable: false)
    ..sort((left, right) {
      final byName = left.key.toLowerCase().compareTo(right.key.toLowerCase());
      return byName != 0 ? byName : left.key.compareTo(right.key);
    });
  final canonical = jsonEncode(<Object?>[
    _profileBindingDomain,
    profile.id,
    profile.adapterKey,
    profile.requestBaseUri().toString(),
    profile.openAiApiMode.storageValue,
    profile.apiKeyAuthMode.storageValue,
    profile.apiVersion,
    profile.apiKey,
    <Object>[
      for (final entry in sortedHeaders) <String>[entry.key, entry.value],
    ],
    profile.allowSelfSignedCertificates,
    profile.mtlsCertificateChainPem,
    profile.mtlsPrivateKeyPem,
    profile.mtlsPrivateKeyPassword,
  ]);
  return base64Url
      .encode(Hmac(sha256, key).convert(utf8.encode(canonical)).bytes)
      .replaceAll('=', '');
}

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}
