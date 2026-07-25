import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/sherpa/sherpa_catalog.dart';
import 'package:conduit/core/sherpa/sherpa_model.dart';
import 'package:conduit/core/sherpa/sherpa_runtime.dart';

void main() {
  test('catalog has valid unique hashes and curated constraints', () {
    validateSherpaCatalog();
    check(
      sherpaModelCatalog.map((model) => model.id).toSet().length,
    ).equals(sherpaModelCatalog.length);
  });

  test('includes every requested Parakeet int8 architecture', () {
    final parakeet = sherpaModelCatalog
        .where((model) => model.family == SherpaModelFamily.parakeet)
        .toList();
    check(parakeet.length).equals(7);
    check(
      parakeet
          .where(
            (model) => model.adapter == SherpaRuntimeAdapter.offlineNemoCtc,
          )
          .length,
    ).equals(2);
    check(
      parakeet
          .where(
            (model) =>
                model.adapter == SherpaRuntimeAdapter.offlineNemoTransducer,
          )
          .length,
    ).equals(4);
    check(
      parakeet
          .where(
            (model) => model.adapter == SherpaRuntimeAdapter.onlineTransducer,
          )
          .single
          .id,
    ).contains('560ms');
    for (final model in parakeet.where(
      (model) =>
          model.adapter == SherpaRuntimeAdapter.offlineNemoTransducer ||
          model.adapter == SherpaRuntimeAdapter.onlineTransducer,
    )) {
      final roles = {
        for (final file in model.runtime.files) file.name: file.pathSuffix,
      };
      check(roles['encoder']).equals('encoder.int8.onnx');
      check(roles['decoder']).equals('decoder.int8.onnx');
      check(roles['joiner']).equals('joiner.int8.onnx');
    }
  });

  test('retained STT roles match their official release archives', () {
    Map<String, String> roles(String id) => {
      for (final file in sherpaModelById(id)!.runtime.files)
        file.name: file.pathSuffix,
    };

    check(roles('sherpa-onnx-whisper-tiny')).deepEquals({
      'encoder': 'tiny-encoder.int8.onnx',
      'decoder': 'tiny-decoder.int8.onnx',
      'tokens': 'tiny-tokens.txt',
    });
    check(
      sherpaModelById('sherpa-onnx-whisper-tiny')!.installedBytes,
    ).equals(256587445);

    for (final language in const ['en', 'de', 'es', 'fr']) {
      final kroko = roles(
        'sherpa-onnx-streaming-zipformer-$language-kroko-2025-08-06',
      );
      check(kroko).deepEquals({
        'tokens': 'tokens.txt',
        'encoder': 'encoder.onnx',
        'decoder': 'decoder.onnx',
        'joiner': 'joiner.onnx',
      });
    }

    check(
      roles('sherpa-onnx-streaming-zipformer-korean-2024-06-16-mobile'),
    ).deepEquals({
      'tokens': 'tokens.txt',
      'encoder': 'encoder-epoch-99-avg-1.int8.onnx',
      'decoder': 'decoder-epoch-99-avg-1.onnx',
      'joiner': 'joiner-epoch-99-avg-1.int8.onnx',
    });
    check(
      roles(
        'sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10',
      ),
    ).deepEquals({
      'tokens': 'tokens.txt',
      'encoder': 'encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      'decoder': 'decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
      'joiner': 'joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
    });
  });

  test('Nemotron exposes only balanced 560 ms int8 builds', () {
    final nemotron = sherpaModelCatalog.where(
      (model) => model.family == SherpaModelFamily.nemotron,
    );
    check(nemotron.length).equals(2);
    for (final model in nemotron) {
      check(model.id).contains('560ms-int8');
      check(model.adapter).equals(SherpaRuntimeAdapter.onlineTransducer);
    }
  });

  test('Nemotron 3.5 marks first-class and broad locale quality', () {
    final model = sherpaModelById(
      'sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11',
    )!;
    final quality = {
      for (final language in model.languages) language.tag: language.quality,
    };
    check(quality['en']).equals(SherpaLanguageQuality.firstClass);
    check(quality['ja']).equals(SherpaLanguageQuality.firstClass);
    check(quality['zh']).equals(SherpaLanguageQuality.supported);
    check(quality['cs']).equals(SherpaLanguageQuality.supported);
  });

  test('Kokoro metadata is limited to English and Chinese', () {
    final english = sherpaModelById('kokoro-int8-en-v0_19')!;
    final bilingual = sherpaModelById('kokoro-int8-multi-lang-v1_1')!;
    check(english.speakers.length).equals(11);
    check(english.speakers.every((speaker) => speaker.name != null)).isTrue();
    check(bilingual.speakers.length).equals(103);
    check(
      bilingual.languages.map((language) => language.tag).toSet(),
    ).deepEquals({'en', 'zh'});
    final roles = {
      for (final file in bilingual.runtime.files) file.name: file.pathSuffix,
    };
    check(roles['lexiconEn']).equals('lexicon-us-en.txt');
    check(roles['lexiconZh']).equals('lexicon-zh.txt');
    check(bilingual.speakers.first.name).equals('af_maple');
    check(bilingual.speakers.last.name).equals('zm_100');
  });

  test('VITS roles match the official Piper and Mimic3 archives', () {
    const expectedModels = {
      'vits-piper-cs_CZ-jirka-medium-int8': 'cs_CZ-jirka-medium.onnx',
      'vits-piper-de_DE-thorsten-medium-int8': 'de_DE-thorsten-medium.onnx',
      'vits-piper-en_US-amy-medium-int8': 'en_US-amy-medium.onnx',
      'vits-piper-es_ES-davefx-medium-int8': 'es_ES-davefx-medium.onnx',
      'vits-piper-fr_FR-siwis-medium-int8': 'fr_FR-siwis-medium.onnx',
      'vits-piper-it_IT-paola-medium-int8': 'it_IT-paola-medium.onnx',
      'vits-piper-nl_NL-ronnie-medium-int8': 'nl_NL-ronnie-medium.onnx',
      'vits-piper-ru_RU-irina-medium-int8': 'ru_RU-irina-medium.onnx',
      'vits-piper-sk_SK-lili-medium-int8': 'sk_SK-lili-medium.onnx',
      'vits-mimic3-ko_KO-kss_low': 'ko_KO-kss_low.onnx',
    };
    for (final entry in expectedModels.entries) {
      final roles = {
        for (final file in sherpaModelById(entry.key)!.runtime.files)
          file.name: file.pathSuffix,
      };
      check(roles['model']).equals(entry.value);
      check(roles['tokens']).equals('tokens.txt');
      check(roles['espeakData']).equals('espeak-ng-data');
    }

    final chineseRoles = {
      for (final file in sherpaModelById(
        'vits-piper-zh_CN-xiao_ya-medium-int8',
      )!.runtime.files)
        file.name: file.pathSuffix,
    };
    check(chineseRoles.containsKey('espeakData')).isFalse();
    check(chineseRoles['model']).equals('zh_CN-xiao_ya-medium.onnx');
    check(chineseRoles['tokens']).equals('tokens.txt');
    check(chineseRoles['lexicon']).equals('lexicon.txt');
    check(chineseRoles['dateFst']).equals('date.fst');
    check(chineseRoles['numberFst']).equals('number.fst');
    check(chineseRoles['phoneFst']).equals('phone.fst');
  });

  test('Supertonic roles match the official release archive', () {
    final roles = {
      for (final file in sherpaModelById(
        'sherpa-onnx-supertonic-3-tts-int8-2026-05-11',
      )!.runtime.files)
        file.name: file.pathSuffix,
    };
    check(roles).deepEquals({
      'durationPredictor': 'duration_predictor.int8.onnx',
      'textEncoder': 'text_encoder.int8.onnx',
      'vectorEstimator': 'vector_estimator.int8.onnx',
      'vocoder': 'vocoder.int8.onnx',
      'ttsJson': 'tts.json',
      'unicodeIndexer': 'unicode_indexer.bin',
      'voiceStyle': 'voice.bin',
    });
  });

  test('Chinese TTS normalization preserves upstream FST order', () {
    check(
      buildSherpaTtsRuleFsts({
        'dateFst': '/model/date.fst',
        'numberFst': '/model/number.fst',
        'phoneFst': '/model/phone.fst',
      }),
    ).equals('/model/phone.fst,/model/date.fst,/model/number.fst');
  });

  test('large models are 64-bit constrained and not auto-recommended', () {
    final large = sherpaModelCatalog.where(
      (model) => model.tier == SherpaModelTier.large,
    );
    check(large.isNotEmpty).isTrue();
    for (final model in large) {
      check(
        model.supportedAbis.every(
          (abi) => abi.contains('64') || abi == 'arm64',
        ),
      ).isTrue();
      if (model.family != SherpaModelFamily.nemotron) {
        check(model.recommended).isFalse();
      }
    }
  });

  test('compact and standard models retain supported 32-bit Android ABIs', () {
    final mobile = sherpaModelCatalog.where(
      (model) => model.tier != SherpaModelTier.large,
    );
    for (final model in mobile) {
      check(model.supportedAbis).contains('armeabi-v7a');
      check(model.supportedAbis).contains('x86');
    }
  });
}
