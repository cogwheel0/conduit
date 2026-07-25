import 'sherpa_model.dart';

const _asrRelease =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/';
const _ttsRelease =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/';
const _docs = 'https://k2-fsa.github.io/sherpa/onnx/';
const _allSupportedAbis = [
  'armeabi-v7a',
  'arm64-v8a',
  'x86',
  'x86_64',
  'arm64',
];
const _supported64BitAbis = ['arm64-v8a', 'x86_64', 'arm64'];
final _apache = SherpaLicense(
  name: 'Apache-2.0',
  url: Uri.parse('https://www.apache.org/licenses/LICENSE-2.0'),
);
final _ccBy4 = SherpaLicense(
  name: 'CC-BY-4.0',
  url: Uri.parse('https://creativecommons.org/licenses/by/4.0/'),
);
final _nvidiaOpenModel = SherpaLicense(
  name: 'NVIDIA Open Model License',
  url: Uri.parse(
    'https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b',
  ),
);
final _openMdw = SherpaLicense(
  name: 'OpenMDW-1.1',
  url: Uri.parse('https://openmdw.ai/license/1-1/'),
);
final _upstreamLicense = SherpaLicense(
  name: 'See upstream model card',
  url: Uri.parse('${_docs}pretrained_models/index.html'),
);

SherpaLanguage _language(
  String tag, {
  SherpaLanguageQuality quality = SherpaLanguageQuality.supported,
}) => SherpaLanguage(tag, quality: quality);

List<SherpaSpeaker> _numberedSpeakers(int count) =>
    List.unmodifiable([for (var i = 0; i < count; i++) SherpaSpeaker(id: i)]);

SherpaModel _stt({
  required String id,
  required String name,
  required SherpaModelFamily family,
  required SherpaRuntimeAdapter adapter,
  required SherpaRecognitionMode mode,
  required List<SherpaLanguage> languages,
  required SherpaModelTier tier,
  required int bytes,
  required int installedBytes,
  required String sha,
  required List<SherpaFileRole> files,
  String release = 'asr-models',
  String modelType = '',
  bool recommended = false,
  String? source,
  SherpaLicense? license,
}) {
  return SherpaModel(
    id: id,
    release: release,
    displayName: name,
    family: family,
    adapter: adapter,
    kind: SherpaModelKind.stt,
    mode: mode,
    languages: languages,
    tier: tier,
    archiveUrl: Uri.parse('$_asrRelease$id.tar.bz2'),
    sha256: sha,
    archiveBytes: bytes,
    installedBytes: installedBytes,
    workingSet: tier == SherpaModelTier.large
        ? SherpaWorkingSet.high
        : tier == SherpaModelTier.standard
        ? SherpaWorkingSet.medium
        : SherpaWorkingSet.low,
    runtime: SherpaRuntimeConfig(
      files: files,
      modelType: modelType,
      threadCount: 2,
    ),
    source: Uri.parse(source ?? '${_docs}pretrained_models/index.html'),
    license: license ?? _upstreamLicense,
    minimumSherpaVersion: '1.13.4',
    supportedAbis: tier == SherpaModelTier.large
        ? _supported64BitAbis
        : _allSupportedAbis,
    recommended: recommended,
  );
}

SherpaModel _tts({
  required String id,
  required String name,
  required SherpaModelFamily family,
  required SherpaRuntimeAdapter adapter,
  required List<SherpaLanguage> languages,
  required int bytes,
  required int installedBytes,
  required String sha,
  required List<SherpaFileRole> files,
  SherpaModelTier tier = SherpaModelTier.compact,
  List<SherpaSpeaker> speakers = const [],
  bool recommended = false,
  String? source,
  SherpaLicense? license,
}) {
  return SherpaModel(
    id: id,
    release: 'tts-models',
    displayName: name,
    family: family,
    adapter: adapter,
    kind: SherpaModelKind.tts,
    mode: SherpaRecognitionMode.offline,
    languages: languages,
    speakers: speakers,
    tier: tier,
    archiveUrl: Uri.parse('$_ttsRelease$id.tar.bz2'),
    sha256: sha,
    archiveBytes: bytes,
    installedBytes: installedBytes,
    workingSet: tier == SherpaModelTier.large
        ? SherpaWorkingSet.high
        : SherpaWorkingSet.medium,
    runtime: SherpaRuntimeConfig(files: files, threadCount: 2),
    source: Uri.parse(source ?? '${_docs}tts/pretrained_models/index.html'),
    license: license ?? _upstreamLicense,
    minimumSherpaVersion: '1.13.4',
    supportedAbis: tier == SherpaModelTier.large
        ? _supported64BitAbis
        : _allSupportedAbis,
    recommended: recommended,
  );
}

const _tokens = SherpaFileRole('tokens', 'tokens.txt');
const _offlineModel = SherpaFileRole('model', 'model.int8.onnx');
const _encoder = SherpaFileRole('encoder', 'encoder.int8.onnx');
const _decoder = SherpaFileRole('decoder', 'decoder.onnx');
const _joiner = SherpaFileRole('joiner', 'joiner.int8.onnx');
const _onlineFiles = [_tokens, _encoder, _decoder, _joiner];
const _nemoTransducerFiles = [
  _tokens,
  _encoder,
  SherpaFileRole('decoder', 'decoder.int8.onnx'),
  _joiner,
];
const _ctcFiles = [_tokens, _offlineModel];
List<SherpaFileRole> _vitsFiles(
  String modelFile, {
  bool usesChineseFrontend = false,
}) => [
  SherpaFileRole('model', modelFile),
  _tokens,
  if (usesChineseFrontend) ...const [
    SherpaFileRole('lexicon', 'lexicon.txt'),
    SherpaFileRole('dateFst', 'date.fst'),
    SherpaFileRole('numberFst', 'number.fst'),
    SherpaFileRole('phoneFst', 'phone.fst'),
  ] else
    const SherpaFileRole('espeakData', 'espeak-ng-data'),
];

final List<SherpaModel> sherpaModelCatalog = List.unmodifiable([
  _stt(
    id: 'sherpa-onnx-whisper-tiny',
    name: 'Whisper Tiny multilingual',
    family: SherpaModelFamily.whisper,
    adapter: SherpaRuntimeAdapter.offlineWhisper,
    mode: SherpaRecognitionMode.offline,
    languages: [
      for (final tag in const [
        'cs',
        'de',
        'en',
        'es',
        'fr',
        'it',
        'ja',
        'ko',
        'nl',
        'ru',
        'sk',
        'zh',
      ])
        _language(tag),
    ],
    tier: SherpaModelTier.standard,
    bytes: 116204861,
    installedBytes: 256587445,
    sha: 'c46116994e539aa165266d96b325252728429c12535eb9d8b6a2b10f129e66b1',
    files: const [
      SherpaFileRole('encoder', 'tiny-encoder.int8.onnx'),
      SherpaFileRole('decoder', 'tiny-decoder.int8.onnx'),
      SherpaFileRole('tokens', 'tiny-tokens.txt'),
    ],
  ),
  _stt(
    id: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09',
    name: 'SenseVoice multilingual int8',
    family: SherpaModelFamily.senseVoice,
    adapter: SherpaRuntimeAdapter.offlineSenseVoice,
    mode: SherpaRecognitionMode.offline,
    languages: [
      for (final tag in const ['zh', 'en', 'ja', 'ko', 'yue']) _language(tag),
    ],
    tier: SherpaModelTier.standard,
    bytes: 165783878,
    installedBytes: 243957894,
    sha: '7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63',
    files: const [_offlineModel, _tokens],
  ),
  ..._zipformerModels,
  ..._parakeetModels,
  ..._nemotronModels,
  ..._ttsModels,
]);

final List<SherpaModel> _zipformerModels = [
  _zipformer(
    'sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06',
    'English Kroko',
    'en',
    57267600,
    'c8676e5ff9ac2a85296e53ee0fd4d5fb1db6770e7a7647166eeafe349ade6834',
    installedBytes: 71237877,
    files: const [
      _tokens,
      SherpaFileRole('encoder', 'encoder.onnx'),
      _decoder,
      SherpaFileRole('joiner', 'joiner.onnx'),
    ],
  ),
  _zipformer(
    'sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06',
    'German Kroko',
    'de',
    57565698,
    '9e27b783c20e67b0d0f13a258c1861fce199917c969d9176a438bee38df64962',
    installedBytes: 71172912,
    files: const [
      _tokens,
      SherpaFileRole('encoder', 'encoder.onnx'),
      _decoder,
      SherpaFileRole('joiner', 'joiner.onnx'),
    ],
  ),
  _zipformer(
    'sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06',
    'Spanish Kroko',
    'es',
    124394665,
    '31b2230a95d23290b308b393da930015a4b2105cb3abb9367aed35f7fcf29cf1',
    installedBytes: 156073899,
    files: const [
      _tokens,
      SherpaFileRole('encoder', 'encoder.onnx'),
      _decoder,
      SherpaFileRole('joiner', 'joiner.onnx'),
    ],
  ),
  _zipformer(
    'sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06',
    'French Kroko',
    'fr',
    57220361,
    'e6ffd3dc43725cd6c8137b05c739f15607d0df946b9b90eb141e10059efca024',
    installedBytes: 71271554,
    files: const [
      _tokens,
      SherpaFileRole('encoder', 'encoder.onnx'),
      _decoder,
      SherpaFileRole('joiner', 'joiner.onnx'),
    ],
  ),
  _zipformer(
    'sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16',
    'Russian Vosk int8',
    'ru',
    24110855,
    '6ba68a01ff3c5445aaf2d61e9b97b026f1149dcc9049d11af3f44f55176341d8',
    installedBytes: 29341602,
  ),
  _zipformerCtc(
    'sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01',
    'Chinese small CTC int8',
    ['zh'],
    21264113,
    // Upstream predates GitHub asset digests. Verified against the release.
    'b3b309f7ce4a737195fcc6963ea19b0653a7d3401580af5ae0d3e284cbb71f0b',
    installedBytes: 27027942,
  ),
  _zipformer(
    'sherpa-onnx-streaming-zipformer-korean-2024-06-16-mobile',
    'Korean mobile',
    'ko',
    377905301,
    // Upstream predates GitHub asset digests. Verified against the release.
    '911187cb71d94df8d8b9bbc1f7684db2d847e4b0259e6f0fb3141e4991711595',
    tier: SherpaModelTier.large,
    installedBytes: 403091644,
    files: const [
      _tokens,
      SherpaFileRole('encoder', 'encoder-epoch-99-avg-1.int8.onnx'),
      SherpaFileRole('decoder', 'decoder-epoch-99-avg-1.onnx'),
      SherpaFileRole('joiner', 'joiner-epoch-99-avg-1.int8.onnx'),
    ],
  ),
  _stt(
    id: 'sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10',
    name: 'Multilingual Zipformer',
    family: SherpaModelFamily.zipformer,
    adapter: SherpaRuntimeAdapter.onlineTransducer,
    mode: SherpaRecognitionMode.streaming,
    languages: [
      for (final tag in const ['ar', 'en', 'id', 'ja', 'ru', 'th', 'vi', 'zh'])
        _language(tag),
    ],
    tier: SherpaModelTier.standard,
    bytes: 258999581,
    installedBytes: 340188059,
    sha: '28044b67324f7f831689f0a3761473dd2ade380e93aa53f1dbcd479ef71c40d4',
    files: const [
      _tokens,
      SherpaFileRole(
        'encoder',
        'encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      ),
      SherpaFileRole(
        'decoder',
        'decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
      ),
      SherpaFileRole(
        'joiner',
        'joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      ),
    ],
    modelType: 'zipformer2',
  ),
];

SherpaModel _zipformer(
  String id,
  String name,
  String language,
  int bytes,
  String sha, {
  SherpaModelTier tier = SherpaModelTier.compact,
  required int installedBytes,
  List<SherpaFileRole> files = _onlineFiles,
}) => _stt(
  id: id,
  name: name,
  family: SherpaModelFamily.zipformer,
  adapter: SherpaRuntimeAdapter.onlineTransducer,
  mode: SherpaRecognitionMode.streaming,
  languages: [_language(language)],
  tier: tier,
  bytes: bytes,
  installedBytes: installedBytes,
  sha: sha,
  files: files,
  modelType: 'zipformer2',
);

SherpaModel _zipformerCtc(
  String id,
  String name,
  List<String> languages,
  int bytes,
  String sha, {
  required int installedBytes,
}) => _stt(
  id: id,
  name: name,
  family: SherpaModelFamily.zipformer,
  adapter: SherpaRuntimeAdapter.onlineZipformer2Ctc,
  mode: SherpaRecognitionMode.streaming,
  languages: languages.map(_language).toList(),
  tier: SherpaModelTier.compact,
  bytes: bytes,
  installedBytes: installedBytes,
  sha: sha,
  files: _ctcFiles,
);

final List<SherpaModel> _parakeetModels = [
  _parakeet(
    'sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8',
    'Parakeet TDT CTC 110M',
    SherpaRuntimeAdapter.offlineNemoCtc,
    104337827,
    '17f945007b52ccd8b7200ffc7c5652e9e8e961dfdf479cefcabd06cf5703630b',
    installedBytes: 131931896,
    files: _ctcFiles,
    license: _ccBy4,
    recommended: true,
  ),
  _parakeet(
    'sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8',
    'Parakeet TDT Transducer 110M',
    SherpaRuntimeAdapter.offlineNemoTransducer,
    108035095,
    'f628312e9fdf8686374cb01a69425c41732529d540860311f16f37cbc32cfe9b',
    installedBytes: 136760193,
    files: _nemoTransducerFiles,
  ),
  _parakeet(
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',
    'Parakeet TDT 0.6B v2',
    SherpaRuntimeAdapter.offlineNemoTransducer,
    482468385,
    '157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad',
    files: _nemoTransducerFiles,
    tier: SherpaModelTier.large,
    installedBytes: 661428477,
    license: _ccBy4,
  ),
  _parakeet(
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    'Parakeet TDT 0.6B v3',
    SherpaRuntimeAdapter.offlineNemoTransducer,
    487170055,
    '5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf',
    files: _nemoTransducerFiles,
    tier: SherpaModelTier.large,
    installedBytes: 671239000,
  ),
  _stt(
    id: 'sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8',
    name: 'Parakeet TDT CTC 0.6B Japanese',
    family: SherpaModelFamily.parakeet,
    adapter: SherpaRuntimeAdapter.offlineNemoCtc,
    mode: SherpaRecognitionMode.offline,
    languages: [_language('ja')],
    tier: SherpaModelTier.large,
    bytes: 489389564,
    installedBytes: 658804775,
    sha: '4b0a800ef29f4f4c8667339bf6f60d5bfdc2852ddc9dc5741aea65b6f8d1306b',
    files: _ctcFiles,
    license: _ccBy4,
  ),
  _parakeet(
    'sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming',
    'Parakeet Unified 0.6B',
    SherpaRuntimeAdapter.offlineNemoTransducer,
    501350460,
    '99f63605b3a85a54c250c0869670a687b7d6598a47bf2421515e1f839a76e150',
    files: _nemoTransducerFiles,
    tier: SherpaModelTier.large,
    installedBytes: 663289365,
  ),
  _parakeet(
    'sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-streaming-560ms',
    'Parakeet Unified 0.6B 560 ms',
    SherpaRuntimeAdapter.onlineTransducer,
    501360769,
    'dd2c2698f102eafbf0ee54bdfd7cd842ec00fa6cf2475cbbb048887f794ff52e',
    files: _nemoTransducerFiles,
    tier: SherpaModelTier.large,
    installedBytes: 663295226,
    streaming: true,
  ),
];

SherpaModel _parakeet(
  String id,
  String name,
  SherpaRuntimeAdapter adapter,
  int bytes,
  String sha, {
  required List<SherpaFileRole> files,
  SherpaModelTier tier = SherpaModelTier.standard,
  required int installedBytes,
  bool recommended = false,
  bool streaming = false,
  SherpaLicense? license,
}) => _stt(
  id: id,
  name: name,
  family: SherpaModelFamily.parakeet,
  adapter: adapter,
  mode: streaming
      ? SherpaRecognitionMode.streaming
      : SherpaRecognitionMode.offline,
  languages: [_language('en', quality: SherpaLanguageQuality.firstClass)],
  tier: tier,
  bytes: bytes,
  installedBytes: installedBytes,
  sha: sha,
  files: files,
  modelType: adapter == SherpaRuntimeAdapter.offlineNemoTransducer
      ? 'nemo_transducer'
      : '',
  recommended: recommended,
  source:
      '${_docs}pretrained_models/offline-transducer/nemo-transducer-models.html',
  license: license ?? _ccBy4,
);

final List<SherpaModel> _nemotronModels = [
  _stt(
    id: 'sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25',
    name: 'Nemotron Speech 0.6B 560 ms',
    family: SherpaModelFamily.nemotron,
    adapter: SherpaRuntimeAdapter.onlineTransducer,
    mode: SherpaRecognitionMode.streaming,
    languages: [_language('en', quality: SherpaLanguageQuality.firstClass)],
    tier: SherpaModelTier.large,
    bytes: 463945051,
    installedBytes: 662744235,
    sha: '78e2b79fcf7271553a74402a76b771b09ea40117a39566a79f52235b23db6358',
    files: _nemoTransducerFiles,
    modelType: 'nemo_transducer',
    source: '${_docs}nemo/nemotron-streaming.html',
    license: _nvidiaOpenModel,
  ),
  _stt(
    id: 'sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11',
    name: 'Nemotron 3.5 ASR 0.6B 560 ms',
    family: SherpaModelFamily.nemotron,
    adapter: SherpaRuntimeAdapter.onlineTransducer,
    mode: SherpaRecognitionMode.streaming,
    languages: [
      for (final tag in const [
        'en',
        'es',
        'fr',
        'it',
        'nl',
        'de',
        'ru',
        'ja',
        'ko',
      ])
        _language(tag, quality: SherpaLanguageQuality.firstClass),
      for (final tag in const ['cs', 'sk', 'zh']) _language(tag),
    ],
    tier: SherpaModelTier.large,
    bytes: 475271763,
    installedBytes: 684574872,
    sha: 'c6bf5e0df765f9d5b43bc9e0536d4b4b3e7d40bdf5ecf13e45f134c51c05ae3a',
    files: _nemoTransducerFiles,
    modelType: 'nemo_transducer',
    recommended: true,
    source: '${_docs}nemo/nemotron-streaming.html',
    license: _openMdw,
  ),
];

final List<SherpaModel> _ttsModels = [
  _tts(
    id: 'sherpa-onnx-supertonic-3-tts-int8-2026-05-11',
    name: 'Supertonic 3 int8',
    family: SherpaModelFamily.supertonic,
    adapter: SherpaRuntimeAdapter.ttsSupertonic,
    languages: [
      for (final tag in const [
        'cs',
        'de',
        'en',
        'es',
        'fr',
        'it',
        'ja',
        'ko',
        'nl',
        'ru',
        'sk',
      ])
        _language(tag),
    ],
    bytes: 128774318,
    installedBytes: 145316356,
    sha: '82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427',
    files: const [
      SherpaFileRole('durationPredictor', 'duration_predictor.int8.onnx'),
      SherpaFileRole('textEncoder', 'text_encoder.int8.onnx'),
      SherpaFileRole('vectorEstimator', 'vector_estimator.int8.onnx'),
      SherpaFileRole('vocoder', 'vocoder.int8.onnx'),
      SherpaFileRole('ttsJson', 'tts.json'),
      SherpaFileRole('unicodeIndexer', 'unicode_indexer.bin'),
      SherpaFileRole('voiceStyle', 'voice.bin'),
    ],
    speakers: _numberedSpeakers(10),
    recommended: true,
  ),
  for (final voice in _piperVoices)
    _tts(
      id: voice.id,
      name: voice.name,
      family: SherpaModelFamily.piper,
      adapter: SherpaRuntimeAdapter.ttsVits,
      languages: [_language(voice.language)],
      bytes: voice.bytes,
      installedBytes: voice.installedBytes,
      sha: voice.sha,
      files: _vitsFiles(
        voice.modelFile,
        usesChineseFrontend: voice.usesChineseFrontend,
      ),
      speakers: const [SherpaSpeaker(id: 0)],
    ),
  _tts(
    id: 'vits-mimic3-ko_KO-kss_low',
    name: 'Korean Mimic3 KSS low',
    family: SherpaModelFamily.mimic3,
    adapter: SherpaRuntimeAdapter.ttsVits,
    languages: [_language('ko')],
    bytes: 66838474,
    installedBytes: 80791421,
    sha: 'f015d1d15a52ed00d6fe22757c5ef4a74283c53daf829c838fa5c22616ed789c',
    files: _vitsFiles('ko_KO-kss_low.onnx'),
    speakers: const [SherpaSpeaker(id: 0, name: 'KSS')],
  ),
  _tts(
    id: 'kokoro-int8-en-v0_19',
    name: 'Kokoro English int8',
    family: SherpaModelFamily.kokoro,
    adapter: SherpaRuntimeAdapter.ttsKokoro,
    languages: [_language('en', quality: SherpaLanguageQuality.firstClass)],
    bytes: 103248205,
    installedBytes: 157947103,
    sha: 'c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd',
    files: _kokoroFiles,
    tier: SherpaModelTier.standard,
    speakers: const [
      SherpaSpeaker(id: 0, name: 'af'),
      SherpaSpeaker(id: 1, name: 'af_bella'),
      SherpaSpeaker(id: 2, name: 'af_nicole'),
      SherpaSpeaker(id: 3, name: 'af_sarah'),
      SherpaSpeaker(id: 4, name: 'af_sky'),
      SherpaSpeaker(id: 5, name: 'am_adam'),
      SherpaSpeaker(id: 6, name: 'am_michael'),
      SherpaSpeaker(id: 7, name: 'bf_emma'),
      SherpaSpeaker(id: 8, name: 'bf_isabella'),
      SherpaSpeaker(id: 9, name: 'bm_george'),
      SherpaSpeaker(id: 10, name: 'bm_lewis'),
    ],
    source: '${_docs}tts/pretrained_models/kokoro.html',
    license: _apache,
  ),
  _tts(
    id: 'kokoro-int8-multi-lang-v1_1',
    name: 'Kokoro English + Chinese int8',
    family: SherpaModelFamily.kokoro,
    adapter: SherpaRuntimeAdapter.ttsKokoro,
    languages: [
      _language('en', quality: SherpaLanguageQuality.firstClass),
      _language('zh', quality: SherpaLanguageQuality.firstClass),
    ],
    bytes: 147031220,
    installedBytes: 215321602,
    sha: 'a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6',
    files: const [
      ..._kokoroFiles,
      SherpaFileRole('lexiconEn', 'lexicon-us-en.txt'),
      SherpaFileRole('lexiconZh', 'lexicon-zh.txt'),
      SherpaFileRole('dateFst', 'date-zh.fst'),
      SherpaFileRole('numberFst', 'number-zh.fst'),
      SherpaFileRole('phoneFst', 'phone-zh.fst'),
    ],
    tier: SherpaModelTier.standard,
    speakers: _kokoroBilingualSpeakers,
    source: '${_docs}tts/all/Chinese-English/kokoro-multi-lang-v1_1.html',
    license: _apache,
  ),
];

const _kokoroFiles = [
  SherpaFileRole('model', 'model.int8.onnx'),
  SherpaFileRole('voices', 'voices.bin'),
  _tokens,
  SherpaFileRole('espeakData', 'espeak-ng-data'),
  SherpaFileRole('dictDir', 'dict', optional: true),
];

const _kokoroBilingualSpeakers = [
  SherpaSpeaker(id: 0, name: 'af_maple'),
  SherpaSpeaker(id: 1, name: 'af_sol'),
  SherpaSpeaker(id: 2, name: 'bf_vale'),
  SherpaSpeaker(id: 3, name: 'zf_001'),
  SherpaSpeaker(id: 4, name: 'zf_002'),
  SherpaSpeaker(id: 5, name: 'zf_003'),
  SherpaSpeaker(id: 6, name: 'zf_004'),
  SherpaSpeaker(id: 7, name: 'zf_005'),
  SherpaSpeaker(id: 8, name: 'zf_006'),
  SherpaSpeaker(id: 9, name: 'zf_007'),
  SherpaSpeaker(id: 10, name: 'zf_008'),
  SherpaSpeaker(id: 11, name: 'zf_017'),
  SherpaSpeaker(id: 12, name: 'zf_018'),
  SherpaSpeaker(id: 13, name: 'zf_019'),
  SherpaSpeaker(id: 14, name: 'zf_021'),
  SherpaSpeaker(id: 15, name: 'zf_022'),
  SherpaSpeaker(id: 16, name: 'zf_023'),
  SherpaSpeaker(id: 17, name: 'zf_024'),
  SherpaSpeaker(id: 18, name: 'zf_026'),
  SherpaSpeaker(id: 19, name: 'zf_027'),
  SherpaSpeaker(id: 20, name: 'zf_028'),
  SherpaSpeaker(id: 21, name: 'zf_032'),
  SherpaSpeaker(id: 22, name: 'zf_036'),
  SherpaSpeaker(id: 23, name: 'zf_038'),
  SherpaSpeaker(id: 24, name: 'zf_039'),
  SherpaSpeaker(id: 25, name: 'zf_040'),
  SherpaSpeaker(id: 26, name: 'zf_042'),
  SherpaSpeaker(id: 27, name: 'zf_043'),
  SherpaSpeaker(id: 28, name: 'zf_044'),
  SherpaSpeaker(id: 29, name: 'zf_046'),
  SherpaSpeaker(id: 30, name: 'zf_047'),
  SherpaSpeaker(id: 31, name: 'zf_048'),
  SherpaSpeaker(id: 32, name: 'zf_049'),
  SherpaSpeaker(id: 33, name: 'zf_051'),
  SherpaSpeaker(id: 34, name: 'zf_059'),
  SherpaSpeaker(id: 35, name: 'zf_060'),
  SherpaSpeaker(id: 36, name: 'zf_067'),
  SherpaSpeaker(id: 37, name: 'zf_070'),
  SherpaSpeaker(id: 38, name: 'zf_071'),
  SherpaSpeaker(id: 39, name: 'zf_072'),
  SherpaSpeaker(id: 40, name: 'zf_073'),
  SherpaSpeaker(id: 41, name: 'zf_074'),
  SherpaSpeaker(id: 42, name: 'zf_075'),
  SherpaSpeaker(id: 43, name: 'zf_076'),
  SherpaSpeaker(id: 44, name: 'zf_077'),
  SherpaSpeaker(id: 45, name: 'zf_078'),
  SherpaSpeaker(id: 46, name: 'zf_079'),
  SherpaSpeaker(id: 47, name: 'zf_083'),
  SherpaSpeaker(id: 48, name: 'zf_084'),
  SherpaSpeaker(id: 49, name: 'zf_085'),
  SherpaSpeaker(id: 50, name: 'zf_086'),
  SherpaSpeaker(id: 51, name: 'zf_087'),
  SherpaSpeaker(id: 52, name: 'zf_088'),
  SherpaSpeaker(id: 53, name: 'zf_090'),
  SherpaSpeaker(id: 54, name: 'zf_092'),
  SherpaSpeaker(id: 55, name: 'zf_093'),
  SherpaSpeaker(id: 56, name: 'zf_094'),
  SherpaSpeaker(id: 57, name: 'zf_099'),
  SherpaSpeaker(id: 58, name: 'zm_009'),
  SherpaSpeaker(id: 59, name: 'zm_010'),
  SherpaSpeaker(id: 60, name: 'zm_011'),
  SherpaSpeaker(id: 61, name: 'zm_012'),
  SherpaSpeaker(id: 62, name: 'zm_013'),
  SherpaSpeaker(id: 63, name: 'zm_014'),
  SherpaSpeaker(id: 64, name: 'zm_015'),
  SherpaSpeaker(id: 65, name: 'zm_016'),
  SherpaSpeaker(id: 66, name: 'zm_020'),
  SherpaSpeaker(id: 67, name: 'zm_025'),
  SherpaSpeaker(id: 68, name: 'zm_029'),
  SherpaSpeaker(id: 69, name: 'zm_030'),
  SherpaSpeaker(id: 70, name: 'zm_031'),
  SherpaSpeaker(id: 71, name: 'zm_033'),
  SherpaSpeaker(id: 72, name: 'zm_034'),
  SherpaSpeaker(id: 73, name: 'zm_035'),
  SherpaSpeaker(id: 74, name: 'zm_037'),
  SherpaSpeaker(id: 75, name: 'zm_041'),
  SherpaSpeaker(id: 76, name: 'zm_045'),
  SherpaSpeaker(id: 77, name: 'zm_050'),
  SherpaSpeaker(id: 78, name: 'zm_052'),
  SherpaSpeaker(id: 79, name: 'zm_053'),
  SherpaSpeaker(id: 80, name: 'zm_054'),
  SherpaSpeaker(id: 81, name: 'zm_055'),
  SherpaSpeaker(id: 82, name: 'zm_056'),
  SherpaSpeaker(id: 83, name: 'zm_057'),
  SherpaSpeaker(id: 84, name: 'zm_058'),
  SherpaSpeaker(id: 85, name: 'zm_061'),
  SherpaSpeaker(id: 86, name: 'zm_062'),
  SherpaSpeaker(id: 87, name: 'zm_063'),
  SherpaSpeaker(id: 88, name: 'zm_064'),
  SherpaSpeaker(id: 89, name: 'zm_065'),
  SherpaSpeaker(id: 90, name: 'zm_066'),
  SherpaSpeaker(id: 91, name: 'zm_068'),
  SherpaSpeaker(id: 92, name: 'zm_069'),
  SherpaSpeaker(id: 93, name: 'zm_080'),
  SherpaSpeaker(id: 94, name: 'zm_081'),
  SherpaSpeaker(id: 95, name: 'zm_082'),
  SherpaSpeaker(id: 96, name: 'zm_089'),
  SherpaSpeaker(id: 97, name: 'zm_091'),
  SherpaSpeaker(id: 98, name: 'zm_095'),
  SherpaSpeaker(id: 99, name: 'zm_096'),
  SherpaSpeaker(id: 100, name: 'zm_097'),
  SherpaSpeaker(id: 101, name: 'zm_098'),
  SherpaSpeaker(id: 102, name: 'zm_100'),
];

typedef _PiperVoice = ({
  String id,
  String name,
  String language,
  String modelFile,
  int bytes,
  int installedBytes,
  String sha,
  bool usesChineseFrontend,
});

const List<_PiperVoice> _piperVoices = [
  (
    id: 'vits-piper-cs_CZ-jirka-medium-int8',
    name: 'Piper Jirka',
    language: 'cs',
    modelFile: 'cs_CZ-jirka-medium.onnx',
    bytes: 21002417,
    installedBytes: 36577622,
    sha: '45377b35ce823eaac5d76a5530b48fb5ad386a4e07db6ff36aa7c417d6bd0a6d',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-de_DE-thorsten-medium-int8',
    name: 'Piper Thorsten',
    language: 'de',
    modelFile: 'de_DE-thorsten-medium.onnx',
    bytes: 20949833,
    installedBytes: 36577367,
    sha: '07e240b7b9c1fc9211d5a69512f8cbe11b3286c2ed79c15c076ac6ed427fdf13',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-en_US-amy-medium-int8',
    name: 'Piper Amy',
    language: 'en',
    modelFile: 'en_US-amy-medium.onnx',
    bytes: 21028122,
    installedBytes: 36679476,
    sha: 'bd23c0aa629eb3719448582f45ede49e8fa6a679061fed5eab16a6a6fd8e7e82',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-es_ES-davefx-medium-int8',
    name: 'Piper DaveFX',
    language: 'es',
    modelFile: 'es_ES-davefx-medium.onnx',
    bytes: 21171632,
    installedBytes: 36577368,
    sha: '8bb8ac1cefb727caec9bd9c6c3185c673c8b42c53bd29bb25d5a7715dac37125',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-fr_FR-siwis-medium-int8',
    name: 'Piper Siwis',
    language: 'fr',
    modelFile: 'fr_FR-siwis-medium.onnx',
    bytes: 20914888,
    installedBytes: 36577449,
    sha: '3909cff9b3cfd4820c66aa13bf554315c82e34899c161f0b446ece372bc4b5ec',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-it_IT-paola-medium-int8',
    name: 'Piper Paola',
    language: 'it',
    modelFile: 'it_IT-paola-medium.onnx',
    bytes: 21143212,
    installedBytes: 36584266,
    sha: '2b975ed305391c056944a4dde67ee754dd824099503a860295bb4c1d724662d8',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-nl_NL-ronnie-medium-int8',
    name: 'Piper Ronnie',
    language: 'nl',
    modelFile: 'nl_NL-ronnie-medium.onnx',
    bytes: 21158108,
    installedBytes: 36341789,
    sha: 'eb16022c9c8ee48b75dc833e8a8b04e08730929ea68cde9b67e2dc712f988978',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-ru_RU-irina-medium-int8',
    name: 'Piper Irina',
    language: 'ru',
    modelFile: 'ru_RU-irina-medium.onnx',
    bytes: 21149417,
    installedBytes: 36577296,
    sha: 'b0000a509f7551a80742eed5c43b8eb03f469cb9f0a42f6feee96ce0da0ebab8',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-sk_SK-lili-medium-int8',
    name: 'Piper Lili',
    language: 'sk',
    modelFile: 'sk_SK-lili-medium.onnx',
    bytes: 21281868,
    installedBytes: 36679574,
    sha: '5adc2ac5af88630cf305da68ba9cfd656e4b72e7f8c7d2deb2f641ef1d740096',
    usesChineseFrontend: false,
  ),
  (
    id: 'vits-piper-zh_CN-xiao_ya-medium-int8',
    name: 'Piper Xiao Ya',
    language: 'zh',
    modelFile: 'zh_CN-xiao_ya-medium.onnx',
    bytes: 14016124,
    installedBytes: 20933412,
    sha: 'eab027e194e70289233cf12308373611fa4e2e96ef2d97354ef433ab663d831f',
    usesChineseFrontend: true,
  ),
];

SherpaModel? sherpaModelById(String? id) {
  if (id == null) return null;
  for (final model in sherpaModelCatalog) {
    if (model.id == id) return model;
  }
  return null;
}

void validateSherpaCatalog() {
  final ids = <String>{};
  for (final model in sherpaModelCatalog) {
    if (!ids.add(model.id)) {
      throw StateError('Duplicate Sherpa model id: ${model.id}');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(model.sha256)) {
      throw StateError('Invalid SHA-256 for ${model.id}');
    }
    if ((model.family == SherpaModelFamily.parakeet ||
            model.family == SherpaModelFamily.nemotron ||
            model.family == SherpaModelFamily.kokoro) &&
        !model.id.contains('int8')) {
      throw StateError('${model.id} must be int8');
    }
    if ((model.family == SherpaModelFamily.parakeet ||
            model.family == SherpaModelFamily.nemotron) &&
        model.mode == SherpaRecognitionMode.streaming &&
        !model.id.contains('560ms')) {
      throw StateError('${model.id} must use the curated 560 ms build');
    }
  }
}
