import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/account_metadata.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../chat/services/file_attachment_service.dart';
import '../widgets/settings_page_scaffold.dart';

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  final _genderController = TextEditingController();
  final _birthDateController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String? _loadedProfileId;
  String _selectedGenderValue = '';
  String _avatarImageUrl = '/user.png';
  bool _avatarUsesInitials = false;
  bool _savingProfile = false;
  bool _changingPassword = false;

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _genderController.dispose();
    _birthDateController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.watch(apiServiceProvider);
    final profileAsync = ref.watch(accountProfileProvider);
    final aboutAsync = ref.watch(serverAboutInfoProvider);

    final profile = profileAsync.asData?.value;
    if (profile != null && _loadedProfileId != profile.id) {
      _populateControllers(profile);
    }

    final passwordChangeEnabled =
        aboutAsync.asData?.value?.enablePasswordChangeForm ?? true;

    return SettingsPageScaffold(
      title: l10n.accountSettingsTitle,
      children: [
        _buildIdentitySection(context, profileAsync),
        settingsSectionGap,
        _buildEditableProfileSection(context, profileAsync, api),
        settingsSectionGap,
        _buildPasswordSection(
          context,
          passwordChangeEnabled: passwordChangeEnabled,
        ),
      ],
    );
  }

  Widget _buildIdentitySection(
    BuildContext context,
    AsyncValue<AccountMetadata?> profileAsync,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.accountDetails),
        const SizedBox(height: Spacing.sm),
        profileAsync.when(
          data: (profile) {
            if (profile == null) {
              return _buildInfoCard(
                context,
                child: Text(l10n.signInToManageAccount),
              );
            }

            return _buildInfoCard(
              context,
              child: Column(
                children: [
                  _buildReadOnlyRow(
                    context,
                    label: l10n.emailLabel,
                    value: profile.email,
                  ),
                  const SizedBox(height: Spacing.sm),
                  _buildReadOnlyRow(
                    context,
                    label: l10n.roleLabel,
                    value: profile.role,
                  ),
                  const SizedBox(height: Spacing.sm),
                  _buildReadOnlyRow(
                    context,
                    label: l10n.accountStatus,
                    value: _statusLabel(context, profile),
                  ),
                ],
              ),
            );
          },
          loading: () => _buildLoadingCard(context, l10n.loadingProfile),
          error: (_, _) =>
              _buildLoadingCard(context, l10n.unableToLoadOpenWebuiSettings),
        ),
      ],
    );
  }

  Widget _buildEditableProfileSection(
    BuildContext context,
    AsyncValue<AccountMetadata?> profileAsync,
    ApiService? api,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.profileDetails),
        const SizedBox(height: Spacing.sm),
        _buildInfoCard(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAvatarSection(context, api),
              const SizedBox(height: Spacing.lg),
              ConduitInput(
                label: l10n.name,
                controller: _nameController,
                isRequired: true,
                onChanged: _handleNameChanged,
              ),
              const SizedBox(height: Spacing.md),
              ConduitInput(
                label: l10n.bioLabel,
                controller: _bioController,
                hint: l10n.bioHint,
                maxLines: 3,
              ),
              const SizedBox(height: Spacing.md),
              _buildGenderField(context),
              const SizedBox(height: Spacing.md),
              _buildBirthDateField(context),
              const SizedBox(height: Spacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: ConduitButton(
                  text: l10n.saveProfile,
                  isLoading: _savingProfile,
                  onPressed: profileAsync.isLoading || _savingProfile
                      ? null
                      : _save,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarSection(BuildContext context, ApiService? api) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.currentAvatar,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.sidebarForeground.withValues(
              alpha: 0.7,
            ),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.md),
        Center(
          child: UserAvatar(
            size: 88,
            imageUrl: _resolvedAvatarUrl(api),
            fallbackText: _avatarFallbackText(context),
          ),
        ),
        const SizedBox(height: Spacing.md),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            ConduitButton(
              text: l10n.uploadFromDevice,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.photo_on_rectangle,
                android: Icons.photo_library_outlined,
              ),
              isSecondary: true,
              isCompact: true,
              onPressed: _savingProfile
                  ? null
                  : () {
                      unawaited(_uploadAvatarFromDevice());
                    },
            ),
            ConduitButton(
              text: l10n.useInitials,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.textformat_abc,
                android: Icons.text_fields,
              ),
              isSecondary: true,
              isCompact: true,
              onPressed: _savingProfile
                  ? null
                  : () => unawaited(_useInitialsAvatar()),
            ),
            ConduitButton(
              text: l10n.removeAvatar,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.delete,
                android: Icons.delete_outline,
              ),
              isSecondary: true,
              isCompact: true,
              onPressed: _savingProfile ? null : _removeAvatar,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGenderField(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final genderLabel = _selectedGenderLabel(l10n, _selectedGenderValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.genderLabel,
          style: theme.bodySmall?.copyWith(
            color: theme.sidebarForeground.withValues(alpha: 0.7),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          onTap: _savingProfile
              ? null
              : () {
                  unawaited(_showGenderPickerSheet());
                },
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.md,
          ),
          backgroundColor: theme.inputBackground,
          borderColor: theme.inputBorder,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  genderLabel,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.chevron_down,
                  android: Icons.arrow_drop_down,
                ),
                color: theme.iconSecondary,
                size: IconSize.small,
              ),
            ],
          ),
        ),
        if (_selectedGenderValue == 'custom') ...[
          const SizedBox(height: Spacing.md),
          ConduitInput(
            label: l10n.customGenderLabel,
            controller: _genderController,
            hint: l10n.customGenderHint,
          ),
        ],
      ],
    );
  }

  Widget _buildBirthDateField(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final selectedDate = _parseBirthDate(_birthDateController.text);
    final dateLabel = selectedDate == null
        ? l10n.selectBirthDate
        : MaterialLocalizations.of(context).formatMediumDate(selectedDate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.birthDateLabel,
          style: theme.bodySmall?.copyWith(
            color: theme.sidebarForeground.withValues(alpha: 0.7),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          onTap: _savingProfile
              ? null
              : () {
                  unawaited(_pickBirthDate());
                },
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      dateLabel,
                      style: theme.bodyMedium?.copyWith(
                        color: selectedDate == null
                            ? theme.sidebarForeground.withValues(alpha: 0.65)
                            : theme.sidebarForeground,
                      ),
                    ),
                  ),
                  Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.calendar,
                      android: Icons.calendar_today_outlined,
                    ),
                    size: 18,
                    color: theme.sidebarForeground.withValues(alpha: 0.8),
                  ),
                ],
              ),
              if (selectedDate != null) ...[
                const SizedBox(height: Spacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: ConduitTextButton(
                    text: l10n.clear,
                    onPressed: _savingProfile
                        ? null
                        : () {
                            setState(_birthDateController.clear);
                          },
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordSection(
    BuildContext context, {
    required bool passwordChangeEnabled,
  }) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.changePasswordTitle),
        const SizedBox(height: Spacing.sm),
        _buildInfoCard(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!passwordChangeEnabled) ...[
                Text(
                  l10n.passwordChangeUnavailable,
                  style: context.conduitTheme.bodyMedium?.copyWith(
                    color: context.conduitTheme.sidebarForeground.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
              ] else ...[
                ConduitInput(
                  label: l10n.currentPassword,
                  controller: _currentPasswordController,
                  obscureText: true,
                ),
                const SizedBox(height: Spacing.md),
                ConduitInput(
                  label: l10n.newPassword,
                  controller: _newPasswordController,
                  obscureText: true,
                ),
                const SizedBox(height: Spacing.md),
                ConduitInput(
                  label: l10n.confirmNewPassword,
                  controller: _confirmPasswordController,
                  obscureText: true,
                ),
                const SizedBox(height: Spacing.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: ConduitButton(
                    text: l10n.changePasswordTitle,
                    isLoading: _changingPassword,
                    onPressed: _changingPassword ? null : _changePassword,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard(BuildContext context, {required Widget child}) {
    return ConduitCard(child: child);
  }

  Widget _buildLoadingCard(BuildContext context, String message) {
    return _buildInfoCard(
      context,
      child: Text(
        message,
        style: context.conduitTheme.bodyMedium?.copyWith(
          color: context.conduitTheme.sidebarForeground.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  Widget _buildReadOnlyRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final theme = context.conduitTheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.bodySmall?.copyWith(
              color: theme.sidebarForeground.withValues(alpha: 0.7),
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            value,
            style: theme.bodyMedium?.copyWith(
              color: theme.sidebarForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  void _populateControllers(AccountMetadata profile) {
    _loadedProfileId = profile.id;
    _nameController.text = profile.name;
    _bioController.text = profile.bio ?? '';
    _applyGender(profile.gender);
    _birthDateController.text = profile.dateOfBirth ?? '';
    _avatarImageUrl = _normalizeAvatarUrl(profile.profileImageUrl);
    _avatarUsesInitials = false;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_nameController.text.trim().isEmpty) {
      UiUtils.showMessage(context, l10n.nameRequired);
      return;
    }
    if (_selectedGenderValue == 'custom' &&
        _genderController.text.trim().isEmpty) {
      UiUtils.showMessage(context, l10n.customGenderRequired);
      return;
    }

    setState(() => _savingProfile = true);
    try {
      final profileImageUrl = _avatarUsesInitials
          ? await _generateInitialsAvatarDataUrl(_nameController.text)
          : _avatarImageUrl;
      await ref
          .read(accountProfileProvider.notifier)
          .save(
            name: _nameController.text,
            profileImageUrl: profileImageUrl,
            bio: _bioController.text,
            gender: _resolvedGender,
            dateOfBirth: _birthDateController.text,
          );
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.profileUpdated);
    } catch (_) {
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.errorMessage);
    } finally {
      if (mounted) {
        setState(() => _savingProfile = false);
      }
    }
  }

  void _handleNameChanged(String _) {
    if (_avatarUsesInitials) {
      unawaited(_useInitialsAvatar());
    }
  }

  void _applyGender(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      _selectedGenderValue = '';
      _genderController.clear();
      return;
    }
    if (normalized == 'male' || normalized == 'female') {
      _selectedGenderValue = normalized;
      _genderController.clear();
      return;
    }
    _selectedGenderValue = 'custom';
    _genderController.text = normalized;
  }

  String _normalizeAvatarUrl(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return '/user.png';
    }
    return trimmed;
  }

  String get _resolvedGender {
    switch (_selectedGenderValue) {
      case 'male':
      case 'female':
        return _selectedGenderValue;
      case 'custom':
        return _genderController.text.trim();
      default:
        return '';
    }
  }

  String _selectedGenderLabel(AppLocalizations l10n, String value) {
    return switch (value) {
      'male' => l10n.genderMale,
      'female' => l10n.genderFemale,
      'custom' => l10n.genderCustom,
      _ => l10n.genderPreferNotToSay,
    };
  }

  String _avatarFallbackText(BuildContext context) {
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isNotEmpty) {
      return trimmedName;
    }
    return AppLocalizations.of(context)!.userFallbackName;
  }

  String _resolvedAvatarUrl(ApiService? api) =>
      resolveUserProfileImageUrl(api, _avatarImageUrl) ?? _avatarImageUrl;

  DateTime? _parseBirthDate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return DateTime.tryParse(trimmed);
  }

  String _formatBirthDate(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    return date.toIso8601String().split('T').first;
  }

  DateTime _clampBirthDate(DateTime value) {
    final minimum = DateTime(1900, 1, 1);
    final maximum = DateTime.now();
    if (value.isBefore(minimum)) {
      return minimum;
    }
    if (value.isAfter(maximum)) {
      return maximum;
    }
    return value;
  }

  Future<void> _pickBirthDate() async {
    final initialDate = _clampBirthDate(
      _parseBirthDate(_birthDateController.text) ?? DateTime(1990, 1, 1),
    );
    final firstDate = DateTime(1900, 1, 1);
    final lastDate = DateTime.now();

    final platform = Theme.of(context).platform;
    final DateTime? selected;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      selected = await _showCupertinoBirthDatePicker(
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
      );
    } else {
      selected = await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
      );
    }

    if (selected == null || !mounted) {
      return;
    }
    final selectedDate = selected;
    setState(() {
      _birthDateController.text = _formatBirthDate(selectedDate);
    });
  }

  Future<void> _showGenderPickerSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final options = <({String value, String label})>[
      (value: '', label: l10n.genderPreferNotToSay),
      (value: 'male', label: l10n.genderMale),
      (value: 'female', label: l10n.genderFemale),
      (value: 'custom', label: l10n.genderCustom),
    ];

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.genderLabel,
          itemCount: options.length,
          initialChildSize: 0.42,
          minChildSize: 0.32,
          maxChildSize: 0.68,
          itemBuilder: (context, index) {
            final option = options[index];
            return SettingsSelectorTile(
              title: option.label,
              selected: _selectedGenderValue == option.value,
              onTap: () {
                setState(() {
                  _selectedGenderValue = option.value;
                  if (_selectedGenderValue != 'custom') {
                    _genderController.clear();
                  }
                });
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  Future<DateTime?> _showCupertinoBirthDatePicker({
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
  }) async {
    DateTime selectedDate = initialDate;

    return showSettingsSheet<DateTime>(
      context: context,
      builder: (context) {
        final theme = context.conduitTheme;
        final textTheme = theme.bodyMedium;

        return SafeArea(
          top: false,
          child: Container(
            color: theme.surfaceContainer,
            padding: const EdgeInsets.only(bottom: Spacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.md,
                    Spacing.sm,
                    Spacing.md,
                    Spacing.xs,
                  ),
                  child: Row(
                    children: [
                      ConduitTextButton(
                        text: MaterialLocalizations.of(
                          context,
                        ).cancelButtonLabel,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      ConduitTextButton(
                        text: MaterialLocalizations.of(context).okButtonLabel,
                        isPrimary: true,
                        onPressed: () =>
                            Navigator.of(context).pop(selectedDate),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 216,
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: initialDate,
                    minimumDate: firstDate,
                    maximumDate: lastDate,
                    onDateTimeChanged: (value) {
                      selectedDate = value;
                    },
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  AppLocalizations.of(context)!.birthDateLabel,
                  style: textTheme?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _uploadAvatarFromDevice() async {
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(fileAttachmentServiceProvider);
    if (service == null) {
      UiUtils.showMessage(context, l10n.avatarUploadFailed);
      return;
    }

    try {
      final attachment = await service.pickImage() as LocalAttachment?;
      if (attachment == null) {
        return;
      }

      final String? dataUrl;
      if (service is FileAttachmentService) {
        dataUrl = await service.convertImageToDataUrl(
          attachment.file,
          enableCompression: true,
          maxWidth: 250,
          maxHeight: 250,
        );
      } else {
        dataUrl = await convertImageFileToDataUrl(attachment.file);
      }

      if (dataUrl == null || dataUrl.isEmpty) {
        if (mounted) {
          UiUtils.showMessage(context, l10n.avatarUploadFailed);
        }
        return;
      }

      if (!mounted) {
        return;
      }
      final resolvedDataUrl = dataUrl;
      setState(() {
        _avatarUsesInitials = false;
        _avatarImageUrl = resolvedDataUrl;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.avatarUploadFailed);
    }
  }

  Future<void> _useInitialsAvatar() async {
    final dataUrl = await _generateInitialsAvatarDataUrl(_nameController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      _avatarUsesInitials = true;
      _avatarImageUrl = dataUrl;
    });
  }

  void _removeAvatar() {
    setState(() {
      _avatarUsesInitials = false;
      _avatarImageUrl = '/user.png';
    });
  }

  Future<String> _generateInitialsAvatarDataUrl(String name) async {
    final initials = _extractInitials(name);
    const dimension = 250;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(dimension / 2, dimension / 2);
    final paint = Paint()..color = _avatarBackgroundColor(name);

    canvas.drawCircle(center, dimension / 2, paint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 88,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(
        (dimension - textPainter.width) / 2,
        (dimension - textPainter.height) / 2,
      ),
    );

    final image = await recorder.endRecording().toImage(dimension, dimension);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData?.buffer.asUint8List();
    if (bytes == null) {
      return '/user.png';
    }
    return 'data:image/png;base64,${base64Encode(bytes)}';
  }

  String _extractInitials(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();

    if (words.isEmpty) {
      return 'U';
    }
    if (words.length == 1) {
      final word = words.first;
      final length = word.length >= 2 ? 2 : 1;
      return word.substring(0, length).toUpperCase();
    }
    return '${words.first[0]}${words[1][0]}'.toUpperCase();
  }

  Color _avatarBackgroundColor(String seed) {
    final normalized = seed.trim().toLowerCase();
    final hue = normalized.isEmpty
        ? 215.0
        : (normalized.hashCode.abs() % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, 0.52).toColor();
  }

  Future<void> _changePassword() async {
    final l10n = AppLocalizations.of(context)!;
    final currentPassword = _currentPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (currentPassword.isEmpty || newPassword.isEmpty) {
      UiUtils.showMessage(context, l10n.passwordFieldsRequired);
      return;
    }
    if (newPassword != confirmPassword) {
      UiUtils.showMessage(context, l10n.passwordsDoNotMatch);
      return;
    }

    setState(() => _changingPassword = true);
    try {
      await ref
          .read(accountProfileProvider.notifier)
          .updatePassword(password: currentPassword, newPassword: newPassword);
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.passwordUpdated);
    } catch (_) {
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.errorMessage);
    } finally {
      if (mounted) {
        setState(() => _changingPassword = false);
      }
    }
  }

  String _statusLabel(BuildContext context, AccountMetadata profile) {
    final l10n = AppLocalizations.of(context)!;
    final base = profile.isActive ? l10n.activeStatus : l10n.inactiveStatus;
    if (!profile.hasStatus) {
      return base;
    }
    final emoji = profile.statusEmoji?.trim() ?? '';
    final message = profile.statusMessage?.trim() ?? '';
    final parts = [
      if (emoji.isNotEmpty) emoji,
      if (message.isNotEmpty) message,
    ];
    if (parts.isEmpty) {
      return base;
    }
    return '$base • ${parts.join(' ')}';
  }
}
