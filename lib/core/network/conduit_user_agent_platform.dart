import 'conduit_user_agent_platform_stub.dart'
    if (dart.library.io) 'conduit_user_agent_platform_io.dart'
    as impl;

String? get runtimeDefaultUserAgent => impl.runtimeDefaultUserAgent;
