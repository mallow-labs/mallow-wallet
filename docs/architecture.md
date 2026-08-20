# Architecture & Coding Style

mallow wallet follows Clean Architecture principles with a focus on feature-driven organization.

## File Organization
Each feature follows this structure:

```
features/
└── feature_name/
    ├── data/           # Repositories, data sources
    ├── models/         # Data models (freezed)
    ├── services/       # Business logic (blocs)
    ├── screens/        # Full-page widgets
    └── widgets/        # Feature-specific components
```

## Naming Conventions
- **Files**: `snake_case` (e.g., `artwork_detail_screen.dart`)
- **Classes**: `PascalCase` (e.g., `ArtworkDetailScreen`)
- **Variables/Functions**: `camelCase` (e.g., `fetchBalances()`)
- **Private Members**: `_camelCase` (e.g., `_repository`)
- **Constants**: `camelCase` or `SCREAMING_SNAKE_CASE`

## State Management (flutter_bloc + freezed)
We use `flutter_bloc` for business logic and `freezed` for immutable state and events.

```dart
@freezed
sealed class ArtworkState with _$ArtworkState {
  const factory ArtworkState.initial() = ArtworkInitial;
  const factory ArtworkState.loading() = ArtworkLoading;
  const factory ArtworkState.loaded(Artwork artwork) = ArtworkLoaded;
  const factory ArtworkState.error(String message) = ArtworkError;
}
```

## Error Handling — `Result<T, E>` and `AppFailure`

Live in `lib/core/result/`:

- **`Result<T, E>`** — sealed class with `ResultSuccess` / `ResultFailure`. Replaces ad-hoc `try`/`catch` blocks that emit string-formatted error states with a typed container that carries the value or the classified failure (plus the stack trace).
- **`AppFailure`** — common bloc failure type with a `kind`, a user-facing `message`, and the original `cause`. `AppFailureKind` has **seven** values — `cancelled`, `network`, `rpc`, `signing`, `validation`, `flowDisabled`, `unknown`. The enum in `core/result/app_failure.dart` is the source of truth and documents what each one means; do not re-list a subset of it elsewhere. Two distinctions are load-bearing: `rpc` is split from `network` so the UI can say "Solana network is busy" rather than a generic API error, and `flowDisabled` (the remote kill switch, or a `(chain, flow)` cell this build does not implement) is deliberately **not** `cancelled` — surfaces that render cancels silently would swallow the operator's message, which is the only copy that can tell a user whether their funds are safe.
  Two `TransactionAuthCancelledException` types — one in `core/crypto/exceptions.dart`, one in `core/security/transaction_auth_gate.dart` — classify as `AppFailureKind.cancelled` via `AppFailure.from(error)`, with one exception: the gate's variant carries the outcome, so `AppFailure.from` re-routes it to `flowDisabled` when that outcome holds a `disabledMessage`.

### When to use

Reach for `Result.guard(...)` instead of `try`/`catch` whenever a bloc handler calls a repository, API client, or signing pipeline that can throw. The classification matters when the UI needs to distinguish "user backed out" from "request failed" — see the cancellation branch in `MarketBloc._onConfirmAndSign`.

### Bloc usage pattern

```dart
Future<void> _onLoad(LoadEvent event, Emitter<MyState> emit) async {
  emit(const MyState.loading());

  final result = await Result.guard(() => _repository.fetchData(event.id));

  switch (result) {
    case ResultSuccess(:final value):
      emit(MyState.loaded(value));
    case ResultFailure(:final error):
      // error is AppFailure — branch on kind when it matters
      if (error.isCancelled) {
        emit(const MyState.initial()); // clean reset
      } else {
        emit(MyState.error(error.message));
      }
  }
}
```

For batch flows (multiple homogeneous prepare handlers), extract a private helper that takes the `build` closure and per-action fields — see `RaffleBloc._runPrepare` for the canonical example.

### Rollout status

All bloc-level `catch (e) { emit(error('...: $e')) }` sites have been migrated to
`Result<T, AppFailure>`. The remaining `try`/`catch`
blocks in blocs are intentional — they wrap fire-and-forget background work
(e.g. drawer reorder persistence, optimistic link/unlink) where the error
surfaces through `debugPrint` and the UI silently falls back. Those do not
need the `Result` wrapper because the caller has already decided how to react.

Canonical patterns to follow when adding a new bloc handler:

- Single repository call → `await Result.guard(() => _repo.fetch(...))` and
  `switch` on the `Result`.
- Multiple homogeneous prepare handlers → extract a private `_runPrepare`
  helper that takes the build closure and per-action fields. See
  `RaffleBloc._runPrepare`.
- Catch lives in pre-existing code that's hard to fully restructure → at
  minimum, route the raw error through `AppFailure.from(e).message` so
  cancellation classification still flows through.

## Widget Patterns
- Prefer composition over deep inheritance.
- Use `const` constructors wherever possible.
- Read colours from `context.mallowColors` (the `MallowColors` theme extension
  in `lib/shared/theme/mallow_colors.dart`). Never hardcode a hex literal, and
  do not use `MallowTheme`'s `static const` colour fields — they are legacy.
