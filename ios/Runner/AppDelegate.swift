import Flutter
import GoogleMaps
import UIKit
import AMapFoundationKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let aMapApiKey = "407057b8ffc12166ca5fb0a904a43645"
    let googleMapsApiKey = "【请将这段文字替换为你申请的 Google Maps API Key】"

    // 高德地图 iOS SDK Key（仅用于底图渲染）+ HTTPS 合规
    AMapServices.shared().apiKey = aMapApiKey
    AMapServices.shared().enableHTTPS = true
    GMSServices.provideAPIKey(googleMapsApiKey)

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
