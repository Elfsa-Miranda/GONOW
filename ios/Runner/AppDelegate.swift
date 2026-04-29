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
    let aMapApiKey = "【请将这段文字替换为你申请的 iOS 高德 Key】"
    let googleMapsApiKey = "【请将这段文字替换为你申请的 Google Maps API Key】"

    AMapServices.shared().apiKey = aMapApiKey
    GMSServices.provideAPIKey(googleMapsApiKey)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
