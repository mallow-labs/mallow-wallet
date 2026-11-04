import 'package:injectable/injectable.dart';

/// A claim on an inbound link. Returns true when it took the link, which then
/// goes no further. [replay] is true when the OS delivered the cold-start link
/// a second time on the link stream.
typedef DeepLinkHandler = bool Function(Uri uri, {required bool replay});

/// Extension point that lets a feature claim inbound links before
/// `DeepLinkService` maps them to a route.
///
/// Inert until something registers: with no handler every link carries on to
/// the routing it had before. A singleton of its own rather than a field of
/// `DeepLinkService`, because `app.dart` rebuilds that service on every boot and
/// Retry, and a registration made once at startup has to outlive it.
@lazySingleton
class DeepLinkHandlerRegistry {
  final List<DeepLinkHandler> _handlers = [];

  /// Adds [handler]. Handlers are asked in registration order.
  void register(DeepLinkHandler handler) => _handlers.add(handler);

  /// Removes [handler]. For tests.
  void unregister(DeepLinkHandler handler) => _handlers.remove(handler);

  /// Offers [uri] to each handler in turn. True once one has consumed it.
  bool handle(Uri uri, {required bool replay}) {
    for (final handler in List.of(_handlers)) {
      if (handler(uri, replay: replay)) return true;
    }
    return false;
  }
}
