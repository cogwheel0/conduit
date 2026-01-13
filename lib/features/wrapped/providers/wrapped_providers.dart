import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../models/wrapped_stats.dart';

part 'wrapped_providers.g.dart';

/// Computes 2025 Wrapped statistics from the user's conversations.
///
/// Filters conversations to only include those from 2025 and computes
/// various engagement metrics for a fun year-in-review experience.
@riverpod
Future<WrappedStats> wrappedStats(WrappedStatsRef ref) async {
  final conversationsAsync = await ref.watch(conversationsProvider.future);
  return _computeWrappedStats(conversationsAsync);
}

/// Filters and computes statistics from conversations.
WrappedStats _computeWrappedStats(List<Conversation> allConversations) {
  // Filter to 2025 conversations only
  final conversations = allConversations.where((conv) {
    return conv.createdAt.year == 2025 || conv.updatedAt.year == 2025;
  }).toList();

  if (conversations.isEmpty) {
    return WrappedStats.empty;
  }

  // Basic counts
  int totalMessages = 0;
  int totalUserMessages = 0;
  int totalAssistantMessages = 0;
  int totalCharactersTyped = 0;
  int totalCharactersReceived = 0;

  // Model usage tracking
  final modelUsageCounts = <String, int>{};

  // Monthly tracking
  final monthlyMessageCounts = <int, int>{};

  // Day of week tracking (1-7)
  final dayOfWeekCounts = <int, int>{};

  // Hour of day tracking (0-23)
  final hourOfDayCounts = <int, int>{};

  // Longest conversation tracking
  String longestConversationTitle = '';
  int longestConversationMessageCount = 0;

  // Date tracking
  DateTime? firstChatDate;
  DateTime? mostRecentChatDate;

  // Days with activity for streak calculation
  final activeDays = <DateTime>{};

  for (final conversation in conversations) {
    // Filter messages to 2025 only
    final messages2025 = conversation.messages.where((msg) {
      return msg.timestamp.year == 2025;
    }).toList();

    if (messages2025.isEmpty) continue;

    totalMessages += messages2025.length;

    // Track longest conversation
    if (messages2025.length > longestConversationMessageCount) {
      longestConversationMessageCount = messages2025.length;
      longestConversationTitle = conversation.title.isNotEmpty
          ? conversation.title
          : 'Untitled Chat';
    }

    for (final message in messages2025) {
      final timestamp = message.timestamp;

      // Track first and last dates
      if (firstChatDate == null || timestamp.isBefore(firstChatDate)) {
        firstChatDate = timestamp;
      }
      if (mostRecentChatDate == null || timestamp.isAfter(mostRecentChatDate)) {
        mostRecentChatDate = timestamp;
      }

      // Track active days
      activeDays.add(DateTime(timestamp.year, timestamp.month, timestamp.day));

      // Monthly counts
      final month = timestamp.month;
      monthlyMessageCounts[month] = (monthlyMessageCounts[month] ?? 0) + 1;

      // Day of week counts
      final dayOfWeek = timestamp.weekday;
      dayOfWeekCounts[dayOfWeek] = (dayOfWeekCounts[dayOfWeek] ?? 0) + 1;

      // Hour of day counts
      final hour = timestamp.hour;
      hourOfDayCounts[hour] = (hourOfDayCounts[hour] ?? 0) + 1;

      // Role-based counting
      if (message.role == 'user') {
        totalUserMessages++;
        totalCharactersTyped += message.content.length;
      } else if (message.role == 'assistant') {
        totalAssistantMessages++;
        totalCharactersReceived += message.content.length;

        // Track model usage
        final modelName = message.model ?? conversation.model ?? 'Unknown';
        if (modelName.isNotEmpty && modelName != 'Unknown') {
          modelUsageCounts[modelName] =
              (modelUsageCounts[modelName] ?? 0) + 1;
        }
      }
    }
  }

  // Find favorite model
  String favoriteModel = '';
  int favoriteModelMessageCount = 0;
  for (final entry in modelUsageCounts.entries) {
    if (entry.value > favoriteModelMessageCount) {
      favoriteModel = entry.key;
      favoriteModelMessageCount = entry.value;
    }
  }

  // Find busiest month
  int busiestMonth = 1;
  int busiestMonthMessageCount = 0;
  for (final entry in monthlyMessageCounts.entries) {
    if (entry.value > busiestMonthMessageCount) {
      busiestMonth = entry.key;
      busiestMonthMessageCount = entry.value;
    }
  }

  // Find busiest day of week
  int busiestDayOfWeek = 1;
  int busiestDayCount = 0;
  for (final entry in dayOfWeekCounts.entries) {
    if (entry.value > busiestDayCount) {
      busiestDayOfWeek = entry.key;
      busiestDayCount = entry.value;
    }
  }

  // Find busiest hour
  int busiestHourOfDay = 12;
  int busiestHourCount = 0;
  for (final entry in hourOfDayCounts.entries) {
    if (entry.value > busiestHourCount) {
      busiestHourOfDay = entry.key;
      busiestHourCount = entry.value;
    }
  }

  // Calculate chatting streak
  final chattingStreak = _calculateLongestStreak(activeDays);

  // Calculate average
  final totalConversations = conversations.length;
  final averageMessagesPerConversation = totalConversations > 0
      ? totalMessages / totalConversations
      : 0.0;

  return WrappedStats(
    totalConversations: totalConversations,
    totalMessages: totalMessages,
    totalUserMessages: totalUserMessages,
    totalAssistantMessages: totalAssistantMessages,
    favoriteModel: favoriteModel,
    favoriteModelMessageCount: favoriteModelMessageCount,
    modelUsageCounts: Map.unmodifiable(modelUsageCounts),
    busiestMonth: busiestMonth,
    busiestMonthMessageCount: busiestMonthMessageCount,
    monthlyMessageCounts: Map.unmodifiable(monthlyMessageCounts),
    longestConversationTitle: longestConversationTitle,
    longestConversationMessageCount: longestConversationMessageCount,
    averageMessagesPerConversation: averageMessagesPerConversation,
    totalCharactersTyped: totalCharactersTyped,
    totalCharactersReceived: totalCharactersReceived,
    firstChatDate: firstChatDate,
    mostRecentChatDate: mostRecentChatDate,
    chattingStreak: chattingStreak,
    busiestDayOfWeek: busiestDayOfWeek,
    busiestHourOfDay: busiestHourOfDay,
  );
}

/// Calculates the longest streak of consecutive days with activity.
int _calculateLongestStreak(Set<DateTime> activeDays) {
  if (activeDays.isEmpty) return 0;

  final sortedDays = activeDays.toList()..sort();
  int longestStreak = 1;
  int currentStreak = 1;

  for (int i = 1; i < sortedDays.length; i++) {
    final diff = sortedDays[i].difference(sortedDays[i - 1]).inDays;
    if (diff == 1) {
      currentStreak++;
      if (currentStreak > longestStreak) {
        longestStreak = currentStreak;
      }
    } else {
      currentStreak = 1;
    }
  }

  return longestStreak;
}
