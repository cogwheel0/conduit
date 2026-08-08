import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform_ui_capabilities.dart';

class MaterialAppData {
  const MaterialAppData({
    this.color,
    this.highContrastTheme,
    this.highContrastDarkTheme,
    this.debugShowMaterialGrid = false,
    this.showPerformanceOverlay = false,
    this.checkerboardRasterCacheImages = false,
    this.checkerboardOffscreenLayers = false,
    this.showSemanticsDebugger = false,
    this.debugShowCheckedModeBanner = false,
    this.shortcuts,
    this.actions,
    this.restorationScopeId,
    this.scrollBehavior,
  });

  final Color? color;
  final ThemeData? highContrastTheme;
  final ThemeData? highContrastDarkTheme;
  final bool debugShowMaterialGrid;
  final bool showPerformanceOverlay;
  final bool checkerboardRasterCacheImages;
  final bool checkerboardOffscreenLayers;
  final bool showSemanticsDebugger;
  final bool debugShowCheckedModeBanner;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;
  final String? restorationScopeId;
  final ScrollBehavior? scrollBehavior;
}

class CupertinoAppData {
  const CupertinoAppData({
    this.color,
    this.showPerformanceOverlay = false,
    this.checkerboardRasterCacheImages = false,
    this.checkerboardOffscreenLayers = false,
    this.showSemanticsDebugger = false,
    this.debugShowCheckedModeBanner = false,
    this.shortcuts,
    this.actions,
    this.restorationScopeId,
    this.scrollBehavior,
  });

  final Color? color;
  final bool showPerformanceOverlay;
  final bool checkerboardRasterCacheImages;
  final bool checkerboardOffscreenLayers;
  final bool showSemanticsDebugger;
  final bool debugShowCheckedModeBanner;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final Map<Type, Action<Intent>>? actions;
  final String? restorationScopeId;
  final ScrollBehavior? scrollBehavior;
}

enum PlatformTarget {
  android,
  ios,
  ios26Plus,
  ios18OrLower,
  web,
  desktop,
  other,
}

/// Flutter application root with Cupertino on iOS and Material elsewhere.
class AdaptiveApp extends StatelessWidget {
  const AdaptiveApp.router({
    super.key,
    this.routerConfig,
    this.routeInformationProvider,
    this.routeInformationParser,
    this.routerDelegate,
    this.backButtonDispatcher,
    this.builder,
    this.title = '',
    this.onGenerateTitle,
    this.themeMode,
    this.materialLightTheme,
    this.materialDarkTheme,
    this.cupertinoLightTheme,
    this.cupertinoDarkTheme,
    this.locale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[Locale('en', 'US')],
    this.material,
    this.cupertino,
    this.scaffoldMessengerKey,
  });

  final RouterConfig<Object>? routerConfig;
  final RouteInformationProvider? routeInformationProvider;
  final RouteInformationParser<Object>? routeInformationParser;
  final RouterDelegate<Object>? routerDelegate;
  final BackButtonDispatcher? backButtonDispatcher;
  final TransitionBuilder? builder;
  final String title;
  final GenerateAppTitle? onGenerateTitle;
  final ThemeMode? themeMode;
  final ThemeData? materialLightTheme;
  final ThemeData? materialDarkTheme;
  final CupertinoThemeData? cupertinoLightTheme;
  final CupertinoThemeData? cupertinoDarkTheme;
  final Locale? locale;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final LocaleListResolutionCallback? localeListResolutionCallback;
  final LocaleResolutionCallback? localeResolutionCallback;
  final Iterable<Locale> supportedLocales;
  final MaterialAppData Function(BuildContext, PlatformTarget)? material;
  final CupertinoAppData Function(BuildContext, PlatformTarget)? cupertino;
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  PlatformTarget get _platformTarget {
    if (PlatformUiCapabilities.usesNativeIOS26) {
      return PlatformTarget.ios26Plus;
    }
    if (PlatformUiCapabilities.isIOS) {
      return PlatformUiCapabilities.iOSMajorVersion > 0
          ? PlatformTarget.ios18OrLower
          : PlatformTarget.ios;
    }
    if (PlatformUiCapabilities.isAndroid) return PlatformTarget.android;
    return PlatformTarget.other;
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUiCapabilities.isIOS) {
      final data =
          material?.call(context, _platformTarget) ?? const MaterialAppData();
      return MaterialApp.router(
        key: key,
        routerConfig: routerConfig,
        routeInformationProvider: routeInformationProvider,
        routeInformationParser: routeInformationParser,
        routerDelegate: routerDelegate,
        backButtonDispatcher: backButtonDispatcher,
        builder: builder,
        title: title,
        onGenerateTitle: onGenerateTitle,
        color: data.color,
        theme: materialLightTheme,
        darkTheme: materialDarkTheme,
        themeMode: themeMode ?? ThemeMode.system,
        locale: locale,
        localizationsDelegates: localizationsDelegates,
        localeListResolutionCallback: localeListResolutionCallback,
        localeResolutionCallback: localeResolutionCallback,
        supportedLocales: supportedLocales,
        debugShowMaterialGrid: data.debugShowMaterialGrid,
        showPerformanceOverlay: data.showPerformanceOverlay,
        checkerboardRasterCacheImages: data.checkerboardRasterCacheImages,
        checkerboardOffscreenLayers: data.checkerboardOffscreenLayers,
        showSemanticsDebugger: data.showSemanticsDebugger,
        debugShowCheckedModeBanner: data.debugShowCheckedModeBanner,
        shortcuts: data.shortcuts,
        actions: data.actions,
        restorationScopeId: data.restorationScopeId,
        scrollBehavior: data.scrollBehavior,
        highContrastTheme: data.highContrastTheme,
        highContrastDarkTheme: data.highContrastDarkTheme,
        scaffoldMessengerKey: scaffoldMessengerKey,
      );
    }

    final data =
        cupertino?.call(context, _platformTarget) ?? const CupertinoAppData();
    final lightTheme =
        cupertinoLightTheme ??
        CupertinoThemeData(
          brightness: Brightness.light,
          primaryColor: materialLightTheme?.colorScheme.primary,
        );
    final darkTheme =
        cupertinoDarkTheme ??
        CupertinoThemeData(
          brightness: Brightness.dark,
          primaryColor: materialDarkTheme?.colorScheme.primary,
        );

    Widget effectiveBuilder(BuildContext context, Widget? child) {
      final brightness = switch (themeMode) {
        ThemeMode.dark => Brightness.dark,
        ThemeMode.light => Brightness.light,
        _ => MediaQuery.platformBrightnessOf(context),
      };
      final themedChild = MediaQuery(
        data: MediaQuery.of(context).copyWith(platformBrightness: brightness),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: CupertinoTheme(
            data: brightness == Brightness.dark ? darkTheme : lightTheme,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      return builder?.call(context, themedChild) ?? themedChild;
    }

    return CupertinoApp.router(
      key: key,
      routerConfig: routerConfig,
      routeInformationProvider: routeInformationProvider,
      routeInformationParser: routeInformationParser,
      routerDelegate: routerDelegate,
      backButtonDispatcher: backButtonDispatcher,
      builder: effectiveBuilder,
      title: title,
      onGenerateTitle: onGenerateTitle,
      color: data.color,
      theme: lightTheme,
      locale: locale,
      localizationsDelegates: localizationsDelegates,
      localeListResolutionCallback: localeListResolutionCallback,
      localeResolutionCallback: localeResolutionCallback,
      supportedLocales: supportedLocales,
      showPerformanceOverlay: data.showPerformanceOverlay,
      checkerboardRasterCacheImages: data.checkerboardRasterCacheImages,
      checkerboardOffscreenLayers: data.checkerboardOffscreenLayers,
      showSemanticsDebugger: data.showSemanticsDebugger,
      debugShowCheckedModeBanner: data.debugShowCheckedModeBanner,
      shortcuts: data.shortcuts,
      actions: data.actions,
      restorationScopeId: data.restorationScopeId,
      scrollBehavior: data.scrollBehavior,
    );
  }
}
