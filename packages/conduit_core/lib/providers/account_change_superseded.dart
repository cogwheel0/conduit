/// An account change, or a step that leads to one (a sign-in's save, a
/// switch the user was asked about), that no longer stands when it comes to
/// commit: another account took charge, or a newer step began, since it was
/// asked for. It changed nothing.
final class AccountChangeSuperseded implements Exception {
  const AccountChangeSuperseded();

  @override
  String toString() => 'AccountChangeSuperseded';
}
