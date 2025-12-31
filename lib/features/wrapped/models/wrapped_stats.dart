import 'package:flutter/foundation.dart';

/// Statistics for a user's 2025 Conduit Wrapped experience.
///
/// Computes various fun metrics from chat history to create
/// a personalized year-in-review summary.
@immutable
class WrappedStats {
  const WrappedStats({
    required this.totalConversations,
    required this.totalMessages,
    required this.totalUserMessages,
    required this.totalAssistantMessages,
    required this.favoriteModel,
    required this.favoriteModelMessageCount,
    required this.modelUsageCounts,
    required this.busiestMonth,
    required this.busiestMonthMessageCount,
    required this.monthlyMessageCounts,
    required this.longestConversationTitle,
    required this.longestConversationMessageCount,
    required this.averageMessagesPerConversation,
    required this.totalCharactersTyped,
    required this.totalCharactersReceived,
    required this.firstChatDate,
    required this.mostRecentChatDate,
    required this.chattingStreak,
    required this.busiestDayOfWeek,
    required this.busiestHourOfDay,
  });

  /// Total number of conversations in 2025.
  final int totalConversations;

  /// Total number of messages (user + assistant) in 2025.
  final int totalMessages;

  /// Total user messages sent.
  final int totalUserMessages;

  /// Total assistant responses received.
  final int totalAssistantMessages;

  /// The most used AI model.
  final String favoriteModel;

  /// Number of messages with the favorite model.
  final int favoriteModelMessageCount;

  /// Map of model name to message count.
  final Map<String, int> modelUsageCounts;

  /// The month with most activity (1-12).
  final int busiestMonth;

  /// Message count in the busiest month.
  final int busiestMonthMessageCount;

  /// Map of month (1-12) to message count.
  final Map<int, int> monthlyMessageCounts;

  /// Title of the longest conversation.
  final String longestConversationTitle;

  /// Message count in the longest conversation.
  final int longestConversationMessageCount;

  /// Average messages per conversation.
  final double averageMessagesPerConversation;

  /// Total characters typed by user.
  final int totalCharactersTyped;

  /// Total characters received from AI.
  final int totalCharactersReceived;

  /// Date of first chat in 2025.
  final DateTime? firstChatDate;

  /// Date of most recent chat.
  final DateTime? mostRecentChatDate;

  /// Longest streak of consecutive chatting days.
  final int chattingStreak;

  /// Most active day of week (1=Monday, 7=Sunday).
  final int busiestDayOfWeek;

  /// Most active hour of day (0-23).
  final int busiestHourOfDay;

  /// Whether there's enough data for a meaningful wrapped.
  bool get hasEnoughData => totalConversations >= 1 && totalMessages >= 2;

  /// Estimated words typed (rough estimate: chars / 5).
  int get estimatedWordsTyped => (totalCharactersTyped / 5).round();

  /// Estimated words read (rough estimate: chars / 5).
  int get estimatedWordsRead => (totalCharactersReceived / 5).round();

  /// Fun personality based on usage patterns.
  String get chatPersonality {
    if (totalMessages > 1000) return 'Power User';
    if (totalMessages > 500) return 'Super Chatter';
    if (totalMessages > 200) return 'Enthusiast';
    if (totalMessages > 50) return 'Explorer';
    if (totalMessages > 10) return 'Curious Mind';
    return 'Getting Started';
  }

  /// Fun fact based on characters typed.
  String get typingFunFact {
    final pages = (totalCharactersTyped / 2000).round();
    if (pages > 100) return "That's a novel's worth of typing!";
    if (pages > 50) return "You've written a short book!";
    if (pages > 20) return 'Enough to fill a magazine!';
    if (pages > 5) return 'A solid essay collection!';
    return 'A great start to your AI journey!';
  }

  /// Month name for busiest month.
  String get busiestMonthName {
    const months = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return months[busiestMonth.clamp(1, 12)];
  }

  /// Day name for busiest day.
  String get busiestDayName {
    const days = [
      '',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[busiestDayOfWeek.clamp(1, 7)];
  }

  /// Hour formatted for display.
  String get busiestHourFormatted {
    if (busiestHourOfDay == 0) return '12 AM';
    if (busiestHourOfDay < 12) return '$busiestHourOfDay AM';
    if (busiestHourOfDay == 12) return '12 PM';
    return '${busiestHourOfDay - 12} PM';
  }

  /// Top 3 models used.
  List<MapEntry<String, int>> get topModels {
    final sorted = modelUsageCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(3).toList();
  }

  /// Empty stats for when there's no data.
  static const WrappedStats empty = WrappedStats(
    totalConversations: 0,
    totalMessages: 0,
    totalUserMessages: 0,
    totalAssistantMessages: 0,
    favoriteModel: '',
    favoriteModelMessageCount: 0,
    modelUsageCounts: {},
    busiestMonth: 1,
    busiestMonthMessageCount: 0,
    monthlyMessageCounts: {},
    longestConversationTitle: '',
    longestConversationMessageCount: 0,
    averageMessagesPerConversation: 0,
    totalCharactersTyped: 0,
    totalCharactersReceived: 0,
    firstChatDate: null,
    mostRecentChatDate: null,
    chattingStreak: 0,
    busiestDayOfWeek: 1,
    busiestHourOfDay: 12,
  );
}
