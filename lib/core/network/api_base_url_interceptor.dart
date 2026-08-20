import 'package:dio/dio.dart';
import '../config/environment.dart';

/// Rejects an API request when the build declares no `API_BASE_URL`.
///
/// [Config.missingApiBaseUrl] was written to be raised "by the client that
/// needs it" and nothing ever raised it — it had zero call sites. `apiBaseUrl`
/// returns `''` and prints a line, so an unconfigured build resolved every API
/// call against an empty base and failed somewhere down in the HTTP stack with
/// a message naming neither the variable nor the cause. Three documents
/// nevertheless described the variable as fail-loud, which is the doc-vs-code
/// defect this pass exists to remove: the honest fix is to make the code match
/// the documentation, not to soften the documentation.
///
/// 🛑 **The check belongs here and not on the getter.** Two things break if a
/// config read throws:
///
///  * Local wallet operations — create, import, reveal a recovery phrase — are
///    documented to work with no backend at all. A throwing getter takes them
///    down with the API, so a fork could not even evaluate the wallet.
///  * This Dio is shared with third-party traffic (Jupiter, the rewards
///    CDN) whose absolute URLs never consult the base.
///
/// So the guard fires at the one moment it is unambiguous: a *relative* path,
/// about to be resolved against nothing.
class ApiBaseUrlInterceptor extends Interceptor {
  const ApiBaseUrlInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // An absolute path ignores the base entirely, so an unset base is not its
    // problem. Only a relative one would silently resolve against nothing.
    final isAbsolute =
        options.path.startsWith('http://') ||
        options.path.startsWith('https://');

    if (isAbsolute || options.baseUrl.isNotEmpty) {
      handler.next(options);
      return;
    }

    final failure = Config.missingApiBaseUrl;
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: failure,
        message: failure.message.toString(),
      ),
      true,
    );
  }
}
