import 'package:freezed_annotation/freezed_annotation.dart';

part 'apple.freezed.dart';
part 'apple.g.dart';

/// Apple's Foundation Models: the one on this Mac (`onDevice`), or the one
/// on Apple's servers (`privateCloudCompute`), which a build without its
/// entitlement never offers (FoundationModels traps on its first request).
enum AppleModelKind { onDevice, privateCloudCompute }

/// Whether a model can answer: the phone's `PlatformPccAvailability`.
/// `unsupported` means never on this Mac as it is (its macOS is too old, or
/// the model is not offered in this build); `unavailable`, not now.
enum AppleAvailability { available, unavailable, unsupported }

/// Why a model cannot answer, for the window to say in its own words.
enum AppleUnavailableReason {
  /// This Mac runs a macOS older than 26.
  systemTooOld,

  /// This Mac cannot run Apple Intelligence.
  deviceNotEligible,

  /// Apple Intelligence is off in System Settings.
  appleIntelligenceNotEnabled,

  /// The model is still downloading, or not ready yet.
  modelNotReady,

  /// No window's engine answered (the app is starting or closing).
  noEngine,

  /// Not offered in this build (Private Cloud Compute without its
  /// entitlement).
  notOffered,

  /// Apple gave a reason this version does not know.
  other,
}

/// What an engine says of one model: what a `status` command's answer
/// carries.
@freezed
abstract class AppleEngineStatus with _$AppleEngineStatus {
  const factory AppleEngineStatus({
    @Default(AppleAvailability.unsupported) AppleAvailability availability,

    /// Why it cannot answer, when [availability] is not `available`.
    AppleUnavailableReason? reason,

    /// The context window the model reported, in tokens; none when it
    /// reported none (or 0).
    int? contextSize,

    /// False when Apple says the Mac's language may not be supported.
    bool? supportsCurrentLocale,
  }) = _AppleEngineStatus;

  factory AppleEngineStatus.fromJson(Map<String, dynamic> json) =>
      _$AppleEngineStatusFromJson(json);
}

/// One of Apple's models as Settings › Direct Connections shows it.
@freezed
abstract class AppleModelStatus with _$AppleModelStatus {
  const factory AppleModelStatus({
    required AppleModelKind model,
    @Default(AppleAvailability.unsupported) AppleAvailability availability,
    AppleUnavailableReason? reason,
    int? contextSize,
    bool? supportsCurrentLocale,
  }) = _AppleModelStatus;

  factory AppleModelStatus.fromJson(Map<String, dynamic> json) =>
      _$AppleModelStatusFromJson(json);
}

/// Apple Intelligence on this Mac: what `apple.status` and `apple.refresh`
/// answer.
@freezed
abstract class AppleModels with _$AppleModels {
  const factory AppleModels({
    /// The models this Mac may offer, in the phone's order: Apple On-Device
    /// only while the build lacks Private Cloud Compute's entitlement.
    @Default(<AppleModelStatus>[]) List<AppleModelStatus> models,
  }) = _AppleModels;

  factory AppleModels.fromJson(Map<String, dynamic> json) =>
      _$AppleModelsFromJson(json);
}

/// One message of the conversation a run sends: `system`, `user` or
/// `assistant`, the last one the user's.
@freezed
abstract class AppleMessage with _$AppleMessage {
  const factory AppleMessage({
    required String role,
    @Default('') String content,
  }) = _AppleMessage;

  factory AppleMessage.fromJson(Map<String, dynamic> json) =>
      _$AppleMessageFromJson(json);
}

/// A tool the model may call during a run (a Direct MCP server's).
@freezed
abstract class AppleToolDefinition with _$AppleToolDefinition {
  const factory AppleToolDefinition({
    required String name,
    @Default('') String description,

    /// Its arguments' JSON Schema, as JSON text.
    @Default('{}') String inputSchemaJson,
  }) = _AppleToolDefinition;

  factory AppleToolDefinition.fromJson(Map<String, dynamic> json) =>
      _$AppleToolDefinitionFromJson(json);
}

/// A run for Apple's model: the conversation, its tools and the options the
/// core's adapter checked.
@freezed
abstract class AppleGeneration with _$AppleGeneration {
  const factory AppleGeneration({
    required String runId,
    required AppleModelKind model,
    @Default(<AppleMessage>[]) List<AppleMessage> messages,
    @Default(<AppleToolDefinition>[]) List<AppleToolDefinition> tools,
    double? temperature,
    int? maximumResponseTokens,
    double? topP,
    int? topK,
    int? seed,
    bool? greedySampling,

    /// A JSON Schema the answer must follow, with its name; both or none.
    String? responseSchemaName,
    String? responseSchemaJson,
  }) = _AppleGeneration;

  factory AppleGeneration.fromJson(Map<String, dynamic> json) =>
      _$AppleGenerationFromJson(json);
}

/// What `apple.command` asks the window's Foundation Models engine to do.
enum AppleCommandKind {
  /// Whether [AppleCommand.model] can answer: answered with
  /// [AppleReport.status].
  status,

  /// Start [AppleCommand.request]. The answer only says it started; its
  /// text, usage and end come as reports naming its run.
  start,

  /// Stop run [AppleCommand.runId]; it reports `done`.
  cancel,

  /// The answer to tool call [AppleCommand.callId] of run
  /// [AppleCommand.runId]: [AppleCommand.toolContent], or
  /// [AppleCommand.toolCancelled], which ends the run's tools.
  toolResult,
}

/// Payload of `apple.command`: the daemon runs the chat (the core's Direct
/// engine and Apple adapter), the window runs Apple's model. Answered with
/// `apple.report` naming [id].
@freezed
abstract class AppleCommand with _$AppleCommand {
  const factory AppleCommand({
    required int id,
    required AppleCommandKind kind,
    AppleModelKind? model,
    AppleGeneration? request,
    String? runId,
    String? callId,
    String? toolContent,
    @Default(false) bool toolCancelled,
  }) = _AppleCommand;

  factory AppleCommand.fromJson(Map<String, dynamic> json) =>
      _$AppleCommandFromJson(json);
}

/// What an [AppleReport] tells, besides answering a command.
enum AppleReportKind {
  /// The window's engine is here (sent each time the window connects):
  /// [AppleReport.supported] says whether this Mac's macOS has Apple's
  /// models, and [AppleReport.runs] which runs it still has.
  ready,

  /// Run [AppleReport.runId] wrote [AppleReport.content].
  content,

  /// Run [AppleReport.runId]'s token counts.
  usage,

  /// Run [AppleReport.runId] failed: [AppleReport.failure] says how.
  failed,

  /// Run [AppleReport.runId] ended (cancelled runs too).
  done,

  /// Run [AppleReport.runId]'s model calls tool [AppleReport.toolName]
  /// with [AppleReport.argumentsJson] as [AppleReport.callId]: answered
  /// with a `toolResult` command.
  toolCall,
}

/// How a run failed: the daemon words it as the phone does.
enum AppleFailure {
  /// The conversation is longer than the model's context.
  contextExceeded,

  /// The model is not ready (its assets are missing).
  notReady,

  /// Apple's guardrails blocked the request.
  guardrail,

  /// The model declined the request.
  refusal,

  /// The model cannot process this request (a language, guide or
  /// capability it lacks).
  unsupported,

  /// The model's answer could not be read.
  decoding,

  /// Too many requests at once.
  busy,
  timedOut,

  /// The request, its schema or a tool's schema was refused before it ran.
  invalidRequest,
  invalidSchema,
  invalidToolSchema,

  /// The model's stream went back on what it had written.
  invalidStream,

  /// The model cannot answer now: [AppleReport.reason] says why.
  unavailable,
  failed,
}

/// Params for `apple.report`: a command's answer ([id]) and/or what the
/// engine did ([kind]).
@freezed
abstract class AppleReport with _$AppleReport {
  const factory AppleReport({
    /// The command answered, if any.
    int? id,

    /// Whether the command was carried out; [error] says why not, for the
    /// log.
    @Default(true) bool ok,
    String? error,

    /// What happened, when it reports an event.
    AppleReportKind? kind,

    /// `ready`: whether this Mac's macOS has Apple's models (26 or later).
    bool? supported,

    /// `ready`: the runs the engine is still running. Runs end with the
    /// session that ran them, so after a reconnect the daemon tells the
    /// engine to stop each one; on the same session it ends any other it
    /// started.
    @Default(<String>[]) List<String> runs,

    /// A `status` command's answer.
    AppleEngineStatus? status,
    String? runId,

    /// A run's reports (`content`, `usage`, `toolCall`, `done`, `failed`)
    /// are numbered from 1 by the window: a number skipped is a report lost
    /// on the way, and the daemon ends the run rather than keep a reply with
    /// words missing.
    int? seq,

    /// Every report a window sends is numbered by it, from 1, as it is sent
    /// (a send tried again keeps its number). The daemon takes a `ready`
    /// only when it is newer than every report it took from that window, and
    /// a `ready` ends only runs whose start the window answered before it: a
    /// late copy of an older one never ends a run started since.
    int? order,
    String? content,
    int? inputTokens,
    int? outputTokens,
    int? reasoningTokens,
    int? totalTokens,
    String? callId,
    String? toolName,
    String? argumentsJson,
    AppleFailure? failure,

    /// `failed` with `unavailable`: why.
    AppleUnavailableReason? reason,
  }) = _AppleReport;

  factory AppleReport.fromJson(Map<String, dynamic> json) =>
      _$AppleReportFromJson(json);
}
