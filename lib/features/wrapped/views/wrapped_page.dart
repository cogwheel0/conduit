import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../models/wrapped_stats.dart';
import '../providers/wrapped_providers.dart';

/// A beautiful, animated 2025 Wrapped experience for Conduit users.
///
/// Displays personalized statistics about the user's AI conversations
/// throughout 2025 with fun animations and insights.
class WrappedPage extends ConsumerStatefulWidget {
  const WrappedPage({super.key});

  @override
  ConsumerState<WrappedPage> createState() => _WrappedPageState();
}

class _WrappedPageState extends ConsumerState<WrappedPage>
    with TickerProviderStateMixin {
  late PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < 5) {
      HapticFeedback.lightImpact();
      _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      HapticFeedback.lightImpact();
      _pageController.previousPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statsAsync = ref.watch(wrappedStatsProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: statsAsync.when(
        data: (stats) => _buildWrappedContent(stats),
        loading: () => _buildLoadingState(),
        error: (error, stack) => _buildErrorState(error),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Container(
      decoration: _buildGradientBackground(0),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: Spacing.lg),
            Text(
              'Preparing your 2025 Wrapped...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(Object error) {
    return Container(
      decoration: _buildGradientBackground(0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 64),
            const SizedBox(height: Spacing.lg),
            Text(
              'Oops! Something went wrong',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: Spacing.md),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Go Back',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWrappedContent(WrappedStats stats) {
    if (!stats.hasEnoughData) {
      return _buildNoDataState();
    }

    return Stack(
      children: [
        // Animated background
        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          decoration: _buildGradientBackground(_currentPage),
        ),

        // Floating particles
        ..._buildFloatingParticles(),

        // Page content
        PageView(
          controller: _pageController,
          onPageChanged: (page) => setState(() => _currentPage = page),
          children: [
            _buildIntroSlide(stats),
            _buildConversationsSlide(stats),
            _buildModelsSlide(stats),
            _buildActivitySlide(stats),
            _buildPersonalitySlide(stats),
            _buildFinalSlide(stats),
          ],
        ),

        // Navigation
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildNavigation(),
        ),

        // Close button
        Positioned(
          top: MediaQuery.of(context).padding.top + Spacing.sm,
          right: Spacing.md,
          child: _buildCloseButton(),
        ),
      ],
    );
  }

  Widget _buildNoDataState() {
    return Container(
      decoration: _buildGradientBackground(0),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '🎉',
                style: TextStyle(fontSize: 80),
              )
                  .animate()
                  .scale(duration: 600.ms, curve: Curves.elasticOut),
              const SizedBox(height: Spacing.xl),
              const Text(
                '2025 is just getting started!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.3),
              const SizedBox(height: Spacing.lg),
              const Text(
                'Start chatting with AI to build your 2025 Wrapped experience. '
                "We'll track your conversations and create a personalized "
                'year-in-review just for you!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.5,
                ),
              ).animate().fadeIn(delay: 500.ms),
              const SizedBox(height: Spacing.xxl),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.xl,
                    vertical: Spacing.md,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppBorderRadius.large),
                  ),
                ),
                child: const Text(
                  'Start Chatting',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ).animate().fadeIn(delay: 700.ms).scale(delay: 700.ms),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _buildGradientBackground(int page) {
    final gradients = [
      [const Color(0xFF667eea), const Color(0xFF764ba2)],
      [const Color(0xFFf093fb), const Color(0xFFf5576c)],
      [const Color(0xFF4facfe), const Color(0xFF00f2fe)],
      [const Color(0xFF43e97b), const Color(0xFF38f9d7)],
      [const Color(0xFFfa709a), const Color(0xFFfee140)],
      [const Color(0xFF667eea), const Color(0xFF764ba2)],
    ];

    final colors = gradients[page.clamp(0, gradients.length - 1)];

    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    );
  }

  List<Widget> _buildFloatingParticles() {
    return List.generate(15, (index) {
      final random = math.Random(index);
      final size = 4.0 + random.nextDouble() * 8;
      final left = random.nextDouble() * MediaQuery.of(context).size.width;
      final top = random.nextDouble() * MediaQuery.of(context).size.height;
      final delay = random.nextInt(3000);
      final duration = 3000 + random.nextInt(4000);

      return Positioned(
        left: left,
        top: top,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.3),
          ),
        )
            .animate(onPlay: (controller) => controller.repeat(reverse: true))
            .fadeIn(delay: Duration(milliseconds: delay))
            .then()
            .moveY(
              begin: 0,
              end: -30,
              duration: Duration(milliseconds: duration),
              curve: Curves.easeInOut,
            ),
      );
    });
  }

  Widget _buildIntroSlide(WrappedStats stats) {
    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '✨',
            style: TextStyle(fontSize: 80),
          )
              .animate()
              .scale(duration: 800.ms, curve: Curves.elasticOut)
              .then()
              .shimmer(duration: 1500.ms, color: Colors.white38),
          const SizedBox(height: Spacing.xl),
          Text(
            'Your 2025',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.5),
          const SizedBox(height: Spacing.xs),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              colors: [Colors.white, Colors.white.withValues(alpha: 0.8)],
            ).createShader(bounds),
            child: const Text(
              'Conduit Wrapped',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 42,
                fontWeight: FontWeight.bold,
                letterSpacing: -1,
              ),
            ),
          ).animate().fadeIn(delay: 600.ms).slideY(begin: 0.5),
          const SizedBox(height: Spacing.xxl),
          Text(
            "Let's see what you accomplished",
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 18,
            ),
          ).animate().fadeIn(delay: 1000.ms),
          const SizedBox(height: Spacing.xxl),
          _AnimatedArrow().animate().fadeIn(delay: 1500.ms),
        ],
      ),
    );
  }

  Widget _buildConversationsSlide(WrappedStats stats) {
    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '💬',
            style: TextStyle(fontSize: 64),
          ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
          const SizedBox(height: Spacing.xl),
          Text(
            'You had',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 20,
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: Spacing.sm),
          _AnimatedCounter(
            value: stats.totalConversations,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 72,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'conversations',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w600,
            ),
          ).animate().fadeIn(delay: 800.ms),
          const SizedBox(height: Spacing.xxl),
          _StatRow(
            icon: Icons.chat_bubble_outline,
            label: 'Total messages',
            value: '${stats.totalMessages}',
          ).animate().fadeIn(delay: 1000.ms).slideX(begin: -0.3),
          const SizedBox(height: Spacing.md),
          _StatRow(
            icon: Icons.edit_outlined,
            label: 'Messages you sent',
            value: '${stats.totalUserMessages}',
          ).animate().fadeIn(delay: 1200.ms).slideX(begin: -0.3),
          const SizedBox(height: Spacing.md),
          _StatRow(
            icon: Icons.smart_toy_outlined,
            label: 'AI responses',
            value: '${stats.totalAssistantMessages}',
          ).animate().fadeIn(delay: 1400.ms).slideX(begin: -0.3),
        ],
      ),
    );
  }

  Widget _buildModelsSlide(WrappedStats stats) {
    final topModels = stats.topModels;

    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '🤖',
            style: TextStyle(fontSize: 64),
          ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
          const SizedBox(height: Spacing.xl),
          Text(
            'Your favorite AI',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 20,
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: Spacing.md),
          if (stats.favoriteModel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.md,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppBorderRadius.large),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                _formatModelName(stats.favoriteModel),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ).animate().fadeIn(delay: 500.ms).scale(delay: 500.ms),
          const SizedBox(height: Spacing.sm),
          if (stats.favoriteModelMessageCount > 0)
            Text(
              '${stats.favoriteModelMessageCount} messages together',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 16,
              ),
            ).animate().fadeIn(delay: 700.ms),
          if (topModels.length > 1) ...[
            const SizedBox(height: Spacing.xxl),
            Text(
              'Your top models',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ).animate().fadeIn(delay: 900.ms),
            const SizedBox(height: Spacing.md),
            ...topModels.asMap().entries.map((entry) {
              final index = entry.key;
              final model = entry.value;
              final medals = ['🥇', '🥈', '🥉'];
              return Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: _ModelRankRow(
                  rank: medals[index],
                  name: _formatModelName(model.key),
                  count: model.value,
                ),
              ).animate().fadeIn(delay: Duration(milliseconds: 1100 + index * 200)).slideX(begin: 0.3);
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildActivitySlide(WrappedStats stats) {
    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '📊',
            style: TextStyle(fontSize: 64),
          ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
          const SizedBox(height: Spacing.xl),
          Text(
            'Your peak AI time',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 20,
            ),
          ).animate().fadeIn(delay: 300.ms),
          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TimeCard(
                label: 'Best Day',
                value: stats.busiestDayName,
                icon: Icons.calendar_today,
              ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.3),
              const SizedBox(width: Spacing.lg),
              _TimeCard(
                label: 'Best Hour',
                value: stats.busiestHourFormatted,
                icon: Icons.access_time,
              ).animate().fadeIn(delay: 700.ms).slideY(begin: 0.3),
            ],
          ),
          const SizedBox(height: Spacing.xxl),
          _StatRow(
            icon: Icons.local_fire_department,
            label: 'Longest streak',
            value: '${stats.chattingStreak} days',
          ).animate().fadeIn(delay: 900.ms).slideX(begin: -0.3),
          const SizedBox(height: Spacing.md),
          _StatRow(
            icon: Icons.star_outline,
            label: 'Busiest month',
            value: stats.busiestMonthName,
          ).animate().fadeIn(delay: 1100.ms).slideX(begin: -0.3),
          const SizedBox(height: Spacing.md),
          _StatRow(
            icon: Icons.chat_outlined,
            label: 'Longest chat',
            value: '${stats.longestConversationMessageCount} messages',
          ).animate().fadeIn(delay: 1300.ms).slideX(begin: -0.3),
        ],
      ),
    );
  }

  Widget _buildPersonalitySlide(WrappedStats stats) {
    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '🏆',
            style: TextStyle(fontSize: 80),
          )
              .animate()
              .scale(duration: 800.ms, curve: Curves.elasticOut)
              .then()
              .shimmer(duration: 1500.ms, color: Colors.amberAccent),
          const SizedBox(height: Spacing.xl),
          Text(
            "You're a",
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 20,
            ),
          ).animate().fadeIn(delay: 400.ms),
          const SizedBox(height: Spacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xl,
              vertical: Spacing.md,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.25),
                  Colors.white.withValues(alpha: 0.1),
                ],
              ),
              borderRadius: BorderRadius.circular(AppBorderRadius.large),
              border: Border.all(color: Colors.white30),
            ),
            child: Text(
              stats.chatPersonality,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
            ),
          ).animate().fadeIn(delay: 600.ms).scale(delay: 600.ms),
          const SizedBox(height: Spacing.xxl),
          _StatBox(
            emoji: '✍️',
            value: _formatNumber(stats.estimatedWordsTyped),
            label: 'words typed',
          ).animate().fadeIn(delay: 1000.ms).slideY(begin: 0.3),
          const SizedBox(height: Spacing.md),
          _StatBox(
            emoji: '📖',
            value: _formatNumber(stats.estimatedWordsRead),
            label: 'words read from AI',
          ).animate().fadeIn(delay: 1200.ms).slideY(begin: 0.3),
          const SizedBox(height: Spacing.lg),
          Text(
            stats.typingFunFact,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
          ).animate().fadeIn(delay: 1400.ms),
        ],
      ),
    );
  }

  Widget _buildFinalSlide(WrappedStats stats) {
    return _SlideContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '🎊',
            style: TextStyle(fontSize: 80),
          )
              .animate()
              .scale(duration: 800.ms, curve: Curves.elasticOut)
              .then()
              .shake(duration: 500.ms, hz: 2),
          const SizedBox(height: Spacing.xl),
          const Text(
            "Here's to 2025!",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.bold,
            ),
          ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.5),
          const SizedBox(height: Spacing.lg),
          Text(
            'You started ${stats.totalConversations} conversations '
            'and exchanged ${stats.totalMessages} messages with AI. '
            "That's amazing!",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              height: 1.5,
            ),
          ).animate().fadeIn(delay: 800.ms),
          const SizedBox(height: Spacing.xxl),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.celebration),
            label: const Text('Continue Chatting'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.xl,
                vertical: Spacing.md,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.large),
              ),
            ),
          ).animate().fadeIn(delay: 1200.ms).scale(delay: 1200.ms),
          const SizedBox(height: Spacing.md),
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              _shareWrapped(stats);
            },
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.share, color: Colors.white70, size: 20),
                SizedBox(width: Spacing.xs),
                Text(
                  'Share your Wrapped',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 1400.ms),
        ],
      ),
    );
  }

  Widget _buildNavigation() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Previous button
            AnimatedOpacity(
              opacity: _currentPage > 0 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IconButton(
                onPressed: _currentPage > 0 ? _previousPage : null,
                icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
              ),
            ),

            // Page indicators
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(6, (index) {
                final isActive = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isActive ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isActive ? Colors.white : Colors.white38,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),

            // Next button
            AnimatedOpacity(
              opacity: _currentPage < 5 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IconButton(
                onPressed: _currentPage < 5 ? _nextPage : null,
                icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return IconButton(
      onPressed: () => Navigator.of(context).pop(),
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black26,
          shape: BoxShape.circle,
        ),
        child: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.xmark,
            android: Icons.close,
          ),
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }

  void _shareWrapped(WrappedStats stats) {
    // In a real app, this would generate and share an image
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'My 2025 Conduit Wrapped: ${stats.totalConversations} chats, '
          '${stats.totalMessages} messages, '
          "I'm a ${stats.chatPersonality}! 🎉",
        ),
        backgroundColor: context.conduitTheme.info,
      ),
    );
  }

  String _formatModelName(String modelId) {
    // Extract a readable name from model ID
    final parts = modelId.split('/');
    final name = parts.last.split(':').first;
    return name
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .map((word) =>
            word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : '')
        .join(' ');
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    }
    if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}

class _SlideContainer extends StatelessWidget {
  final Widget child;

  const _SlideContainer({required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl,
          vertical: Spacing.xxl,
        ),
        child: child,
      ),
    );
  }
}

class _AnimatedCounter extends StatefulWidget {
  final int value;
  final TextStyle style;

  const _AnimatedCounter({required this.value, required this.style});

  @override
  State<_AnimatedCounter> createState() => _AnimatedCounterState();
}

class _AnimatedCounterState extends State<_AnimatedCounter>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<int> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = IntTween(begin: 0, end: widget.value).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Text(
          '${_animation.value}',
          style: widget.style,
        );
      },
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: Colors.white60, size: 20),
        const SizedBox(width: Spacing.sm),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 16),
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _ModelRankRow extends StatelessWidget {
  final String rank;
  final String name;
  final int count;

  const _ModelRankRow({
    required this.rank,
    required this.name,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(rank, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: Spacing.sm),
        Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          '($count)',
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
      ],
    );
  }
}

class _TimeCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _TimeCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppBorderRadius.large),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white70, size: 24),
          const SizedBox(height: Spacing.sm),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String emoji;
  final String value;
  final String label;

  const _StatBox({
    required this.emoji,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(width: Spacing.sm),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
      ],
    );
  }
}

class _AnimatedArrow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.keyboard_arrow_right,
      color: Colors.white60,
      size: 32,
    )
        .animate(onPlay: (controller) => controller.repeat(reverse: true))
        .moveX(begin: -5, end: 5, duration: 800.ms);
  }
}
