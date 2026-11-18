import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth/session.dart';
import 'features/auth/code_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/home/home_screen.dart';
import 'features/splash/splash_screen.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const signIn = '/sign-in';
  static const signInCode = '/sign-in/code';
  static const profileSetup = '/profile-setup';
  static const home = '/';
}

/// Where the session state says the user must be, or null to stay on [location].
String? sessionRedirect(SessionState session, String location) {
  final target = switch (session.status) {
    SessionStatus.unknown => Routes.splash,
    SessionStatus.signedOut => Routes.signIn,
    SessionStatus.signedIn when session.me?.profileComplete != true =>
      Routes.profileSetup,
    SessionStatus.signedIn => null,
  };
  if (target != null) {
    // Sign-in has nested steps (e.g. /sign-in/code); keep them.
    return location == target || location.startsWith('$target/') ? null : target;
  }
  // Signed in with a profile: leave the gate screens.
  const gates = [Routes.splash, Routes.signIn, Routes.profileSetup];
  return gates.any((g) => location == g || location.startsWith('$g/'))
      ? Routes.home
      : null;
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-runs redirects whenever the session changes.
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) =>
        sessionRedirect(ref.read(sessionProvider), state.matchedLocation),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: Routes.signIn,
        builder: (_, _) => const PhoneScreen(),
        routes: [
          GoRoute(path: 'code', builder: (_, _) => const CodeScreen()),
        ],
      ),
      // Placeholder until profile setup (T047).
      GoRoute(
        path: Routes.profileSetup,
        builder: (_, _) => const _Placeholder('Profile setup'),
      ),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('Coming soon')),
      );
}
