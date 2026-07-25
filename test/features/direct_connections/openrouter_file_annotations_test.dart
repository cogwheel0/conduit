import 'dart:convert';

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_local_document_service.dart';
import 'package:conduit/features/direct_connections/services/openrouter_file_annotations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = <int>[1, 2, 3, 4, 5, 6, 7, 8];
  final profile = DirectConnectionProfile(
    id: 'openrouter',
    name: 'OpenRouter',
    adapterKey: kOpenAiCompatibleAdapterKey,
    baseUrl: kOpenRouterApiBaseUrl,
    apiKey: 'secret',
  );
  final annotation = <String, dynamic>{
    'type': 'file',
    'file': <String, dynamic>{
      'hash': 'stable-pdf-hash',
      'name': 'brief.pdf',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'Parsed reference'},
      ],
    },
  };

  test('file annotations are normalized, signed, and mutation-resistant', () {
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
      attachmentIds: const <String>['direct-openrouter-pdf:brief'],
    );

    expect(
      trustedOpenRouterFileAnnotations(
        envelope,
        verificationKey: key,
        profile: profile,
      ),
      <Map<String, dynamic>>[annotation],
    );

    final changed = Map<String, dynamic>.from(envelope);
    changed['annotations'] = <Map<String, dynamic>>[
      <String, dynamic>{
        ...annotation,
        'file': <String, dynamic>{
          ...(annotation['file'] as Map<String, dynamic>),
          'hash': 'forged',
        },
      },
    ];
    expect(
      trustedOpenRouterFileAnnotations(
        changed,
        verificationKey: key,
        profile: profile,
      ),
      isEmpty,
    );

    final changedAttachment = Map<String, dynamic>.from(envelope)
      ..['attachmentIds'] = const <String>['direct-openrouter-pdf:different'];
    expect(
      trustedOpenRouterFileAnnotationEnvelope(
        changedAttachment,
        verificationKey: key,
        profile: profile,
      ).attachmentIds,
      isEmpty,
    );
  });

  test('file annotations are bound to the exact OpenRouter account', () {
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
    );

    expect(
      trustedOpenRouterFileAnnotations(
        envelope,
        verificationKey: key,
        profile: profile.copyWith(apiKey: 'different-account'),
      ),
      isEmpty,
    );
    expect(
      trustedOpenRouterFileAnnotations(
        envelope,
        verificationKey: key,
        profile: DirectConnectionProfile(
          id: 'generic',
          name: 'Generic',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secret',
        ),
      ),
      isEmpty,
    );
  });

  test('file annotations reject a different device key', () {
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
    );

    expect(
      trustedOpenRouterFileAnnotations(
        envelope,
        verificationKey: const <int>[9, 9, 9, 9, 9, 9, 9, 9],
        profile: profile,
      ),
      isEmpty,
    );
  });

  test('file annotations reject blanked attachment IDs', () {
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
      attachmentIds: const <String>['direct-openrouter-pdf:brief'],
    );
    final blanked = Map<String, dynamic>.from(envelope)
      ..['attachmentIds'] = const <String>[];

    expect(
      trustedOpenRouterFileAnnotations(
        blanked,
        verificationKey: key,
        profile: profile,
      ),
      isEmpty,
    );
  });

  test(
    'replayed annotations retain PDF context without persisted raw bytes',
    () async {
      const attachmentId =
          '${kDirectOpenRouterPdfAttachmentPrefix}opaque-attachment';
      final envelope = signedOpenRouterFileAnnotations(
        annotations: <Map<String, dynamic>>[annotation],
        signingKey: key,
        profile: profile,
        attachmentIds: const <String>[attachmentId],
      );
      final messages = await buildDirectChatMessages(
        directDocumentVerificationKey: key,
        openRouterProfile: profile,
        messages: <ChatMessage>[
          ChatMessage(
            id: 'user',
            role: 'user',
            content: 'Summarize it',
            timestamp: DateTime.utc(2026),
            attachmentIds: const <String>[attachmentId],
            files: const <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'file',
                'source': 'direct_openrouter_pdf',
                'url': attachmentId,
                'name': 'brief.pdf',
                'content_type': 'application/pdf',
              },
            ],
          ),
          ChatMessage(
            id: 'assistant',
            role: 'assistant',
            content: 'Summary',
            timestamp: DateTime.utc(2026),
            metadata: <String, dynamic>{
              'transport': kDirectTransport,
              kOpenRouterFileAnnotationsMetadataKey: envelope,
            },
          ),
        ],
      );

      expect(messages, hasLength(2));
      expect(messages.first.parts.whereType<DirectFilePart>(), isEmpty);
      expect(messages.last.annotations, <Map<String, dynamic>>[annotation]);
    },
  );

  test('current PDF bytes remain ephemeral normalized input', () async {
    const attachmentId =
        '${kDirectOpenRouterPdfAttachmentPrefix}current-attachment';
    final pdf = base64Encode(utf8.encode('%PDF-1.4'));
    final messages = await buildDirectChatMessages(
      messages: <ChatMessage>[
        ChatMessage(
          id: 'user',
          role: 'user',
          content: 'Read it',
          timestamp: DateTime.utc(2026),
          attachmentIds: const <String>[attachmentId, attachmentId],
          files: const <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'file',
              'source': 'direct_openrouter_pdf',
              'url': attachmentId,
              'name': 'brief.pdf',
              'content_type': 'application/pdf',
            },
          ],
        ),
      ],
      ephemeralFilePartsByAttachmentId: <String, DirectFilePart>{
        attachmentId: DirectFilePart(
          filename: 'brief.pdf',
          dataUrl: 'data:application/pdf;base64,$pdf',
        ),
      },
    );

    expect(
      messages.single.parts.whereType<DirectFilePart>().single.filename,
      'brief.pdf',
    );
  });

  test('archived annotations cannot authorize unavailable PDF bytes', () async {
    const attachmentId =
        '${kDirectOpenRouterPdfAttachmentPrefix}archived-attachment';
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
      attachmentIds: const <String>[attachmentId],
    );

    await expectLater(
      buildDirectChatMessages(
        directDocumentVerificationKey: key,
        openRouterProfile: profile,
        messages: <ChatMessage>[
          ChatMessage(
            id: 'user',
            role: 'user',
            content: 'Read it',
            timestamp: DateTime.utc(2026),
            attachmentIds: const <String>[attachmentId],
            files: const <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'file',
                'source': 'direct_openrouter_pdf',
                'url': attachmentId,
              },
            ],
          ),
          ChatMessage(
            id: 'archived-assistant',
            role: 'assistant',
            content: 'Superseded answer',
            timestamp: DateTime.utc(2026),
            metadata: <String, dynamic>{
              'archivedVariant': true,
              kOpenRouterFileAnnotationsMetadataKey: envelope,
            },
          ),
        ],
      ),
      throwsA(isA<DirectChatInputException>()),
    );
  });

  test(
    'an earlier annotation cannot authorize a later unavailable PDF',
    () async {
      const earlierId =
          '${kDirectOpenRouterPdfAttachmentPrefix}earlier-attachment';
      const unavailableId =
          '${kDirectOpenRouterPdfAttachmentPrefix}unavailable-attachment';
      final envelope = signedOpenRouterFileAnnotations(
        annotations: <Map<String, dynamic>>[annotation],
        signingKey: key,
        profile: profile,
        attachmentIds: const <String>[earlierId],
      );

      await expectLater(
        buildDirectChatMessages(
          directDocumentVerificationKey: key,
          openRouterProfile: profile,
          messages: <ChatMessage>[
            ChatMessage(
              id: 'earlier-user',
              role: 'user',
              content: 'Read the first PDF',
              timestamp: DateTime.utc(2026),
              attachmentIds: const <String>[earlierId],
              files: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'file',
                  'source': 'direct_openrouter_pdf',
                  'url': earlierId,
                },
              ],
            ),
            ChatMessage(
              id: 'earlier-assistant',
              role: 'assistant',
              content: 'First answer',
              timestamp: DateTime.utc(2026),
              metadata: <String, dynamic>{
                kOpenRouterFileAnnotationsMetadataKey: envelope,
              },
            ),
            ChatMessage(
              id: 'later-user',
              role: 'user',
              content: 'Read the second PDF',
              timestamp: DateTime.utc(2026),
              attachmentIds: const <String>[unavailableId],
              files: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'file',
                  'source': 'direct_openrouter_pdf',
                  'url': unavailableId,
                },
              ],
            ),
          ],
        ),
        throwsA(isA<DirectChatInputException>()),
      );
    },
  );

  test('each unavailable PDF requires its own signed association', () async {
    const firstId = '${kDirectOpenRouterPdfAttachmentPrefix}first';
    const secondId = '${kDirectOpenRouterPdfAttachmentPrefix}second';
    final envelope = signedOpenRouterFileAnnotations(
      annotations: <Map<String, dynamic>>[annotation],
      signingKey: key,
      profile: profile,
      attachmentIds: const <String>[firstId],
    );

    await expectLater(
      buildDirectChatMessages(
        directDocumentVerificationKey: key,
        openRouterProfile: profile,
        messages: <ChatMessage>[
          ChatMessage(
            id: 'user',
            role: 'user',
            content: 'Compare both PDFs',
            timestamp: DateTime.utc(2026),
            attachmentIds: const <String>[firstId, secondId],
            files: const <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'file',
                'source': 'direct_openrouter_pdf',
                'url': firstId,
              },
              <String, dynamic>{
                'type': 'file',
                'source': 'direct_openrouter_pdf',
                'url': secondId,
              },
            ],
          ),
          ChatMessage(
            id: 'assistant',
            role: 'assistant',
            content: 'Partial answer',
            timestamp: DateTime.utc(2026),
            metadata: <String, dynamic>{
              kOpenRouterFileAnnotationsMetadataKey: envelope,
            },
          ),
        ],
      ),
      throwsA(isA<DirectChatInputException>()),
    );
  });

  test('replayed PDF context is bounded across the whole request', () async {
    final messages = <ChatMessage>[];
    for (var index = 0; index < kOpenRouterMaxFileAnnotations + 1; index++) {
      final perFileAnnotation = <String, dynamic>{
        'type': 'file',
        'file': <String, dynamic>{
          'hash': 'hash-$index',
          'name': 'file-$index.pdf',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'Parsed $index'},
          ],
        },
      };
      messages.add(
        ChatMessage(
          id: 'assistant-$index',
          role: 'assistant',
          content: 'Answer $index',
          timestamp: DateTime.utc(2026),
          metadata: <String, dynamic>{
            kOpenRouterFileAnnotationsMetadataKey:
                signedOpenRouterFileAnnotations(
                  annotations: <Map<String, dynamic>>[perFileAnnotation],
                  signingKey: key,
                  profile: profile,
                ),
          },
        ),
      );
    }

    await expectLater(
      buildDirectChatMessages(
        messages: messages,
        directDocumentVerificationKey: key,
        openRouterProfile: profile,
      ),
      throwsA(isA<DirectChatInputException>()),
    );
  });

  test('annotation names bind only matching ephemeral attachments', () {
    final matched = openRouterPdfAttachmentIdsForAnnotations(
      ephemeralFilePartsByAttachmentId: <String, DirectFilePart>{
        'first': const DirectFilePart(
          filename: 'brief.pdf',
          dataUrl: 'data:application/pdf;base64,JVBERi0=',
        ),
        'second': const DirectFilePart(
          filename: 'other.pdf',
          dataUrl: 'data:application/pdf;base64,JVBERi0=',
        ),
      },
      annotations: <Map<String, dynamic>>[annotation],
    );

    expect(matched, const <String>['first']);
  });
}
