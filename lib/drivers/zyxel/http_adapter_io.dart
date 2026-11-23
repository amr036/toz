import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';

/// Android/desktop: own cookie jar + accept the router's self-signed TLS
/// certificate for the gateway host ONLY.
void configureRouterHttp(Dio dio, CookieJar jar, String gatewayHost) {
  dio.interceptors.add(CookieManager(jar));
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..badCertificateCallback = (cert, host, port) => host == gatewayHost,
  );
}
