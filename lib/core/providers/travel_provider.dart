import 'package:flutter/foundation.dart';
import 'package:gonow/core/models/city_model.dart';
import 'package:gonow/core/services/travel_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TravelProvider extends ChangeNotifier {
  TravelProvider({TravelService? service}) : _service = service ?? const TravelService();

  final TravelService _service;

  List<CityModel> cities = <CityModel>[];
  Map<String, List<Map<String, dynamic>>> visaFreeData =
      <String, List<Map<String, dynamic>>>{};
  bool isBlindBoxLoading = false;
  String? blindBoxError;
  List<Map<String, dynamic>> culturalCustoms = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> internationalCountries = <Map<String, dynamic>>[];
  bool isIntlLoading = true;
  String? intlError;
  bool isVisaLoading = false;
  String? visaError;
  bool _blindBoxLoaded = false;
  bool _intlLoaded = false;
  bool _visaLoaded = false;

  void loadDiscoveryData({bool force = false}) {
    refreshBlindBox(force: force);
    fetchInternationalCountries(force: force);
    refreshVisaData(force: force);
  }

  Future<void> refreshBlindBox({bool force = false}) async {
    if (_blindBoxLoaded && !force) {
      return;
    }
    isBlindBoxLoading = true;
    blindBoxError = null;
    notifyListeners();

    try {
      cities = await _service.fetchBlindBoxCities();
      _blindBoxLoaded = true;
    } on TravelServiceException catch (e) {
      blindBoxError = e.message;
    } catch (_) {
      blindBoxError = '盲盒数据加载失败，请稍后重试';
    } finally {
      isBlindBoxLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshVisaData({bool force = false}) async {
    if (_visaLoaded && !force) {
      return;
    }
    isVisaLoading = true;
    visaError = null;
    notifyListeners();

    try {
      visaFreeData = await _service.fetchVisaFreeCountries();
      _visaLoaded = true;
    } on TravelServiceException catch (e) {
      visaError = e.message;
    } catch (_) {
      visaError = '免签数据加载失败，请稍后重试';
    } finally {
      isVisaLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchInternationalCountries({bool force = false}) async {
    if (_intlLoaded && !force) {
      return;
    }
    isIntlLoading = true;
    intlError = null;
    notifyListeners();

    try {
      internationalCountries = await _service.fetchInternationalCountries();
      _intlLoaded = true;
    } on TravelServiceException catch (e) {
      intlError = e.message;
    } catch (_) {
      intlError = '国际盲盒加载失败，请稍后重试';
    } finally {
      isIntlLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchCulturalCustoms() async {
    try {
      final List<dynamic> response =
          await Supabase.instance.client.from('cultural_customs').select();
      culturalCustoms = List<Map<String, dynamic>>.from(response);
      notifyListeners();
      debugPrint('成功拉取风俗避坑数据: ${culturalCustoms.length} 条');
    } catch (e) {
      debugPrint('获取风俗数据失败: $e');
    }
  }
}
