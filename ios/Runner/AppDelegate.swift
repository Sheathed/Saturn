import Flutter
import Network
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var proxyChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      proxyChannel = FlutterMethodChannel(
        name: "s.s.saturn/webview_proxy",
        binaryMessenger: controller.binaryMessenger
      )
      proxyChannel?.setMethodCallHandler { call, result in
        guard call.method == "configure" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let args = call.arguments as? [String: Any]
        guard #available(iOS 17.0, *) else {
          if args?["address"] == nil { result(nil); return }
          result(FlutterError(code: "UNSUPPORTED", message: "WebView proxy requires iOS 17", details: nil))
          return
        }
        guard let address = args?["address"] as? String, !address.isEmpty else {
          WKWebsiteDataStore.default().proxyConfigurations = []
          result(nil)
          return
        }
        guard let components = URLComponents(string: "http://\(address)"),
              let host = components.host,
              let port = components.port,
              let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
          result(FlutterError(code: "INVALID_PROXY", message: "Invalid proxy address", details: nil))
          return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: networkPort)
        var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        if let username = args?["username"] as? String, !username.isEmpty {
          proxy.applyCredential(username: username, password: args?["password"] as? String ?? "")
        }
        proxy.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        WKWebsiteDataStore.default().proxyConfigurations = [proxy]
        result(nil)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
