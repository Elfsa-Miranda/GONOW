class TravelImageHelper {
  TravelImageHelper._();

  static const String _defaultImage =
      'https://images.unsplash.com/photo-1540206395-68808572332f?w=800';

  static const List<String> _fallbackPool = <String>[
    'https://images.unsplash.com/photo-1501785888041-af3ef285b470?w=1200',
    'https://images.unsplash.com/photo-1476514525535-07fb3b4ae5f1?w=1200',
    'https://images.unsplash.com/photo-1469474968028-56623f02e42e?w=1200',
    'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?w=1200',
    'https://images.unsplash.com/photo-1521292270410-a8c4d716d518?w=1200',
  ];

  static const Map<String, String> _keywordImageMap = <String, String>{
    '北京': 'https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=1200',
    '上海': 'https://images.unsplash.com/photo-1548013146-72479768bada?w=1200',
    '三亚': 'https://images.unsplash.com/photo-1540206395-68808572332f?w=1200',
    '大理': 'https://images.unsplash.com/photo-1596484552834-6a58f850d0a1?w=1200',
    '新疆': 'https://images.unsplash.com/photo-1543817112-68c3447fb905?w=1200',
    '海': 'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?w=1200',
    '雪': 'https://images.unsplash.com/photo-1483664852095-d6cc6870702d?w=1200',
    '山': 'https://images.unsplash.com/photo-1464822759844-d150baec0134?w=1200',
  };

  static String getImageUrlForDestination(String destinationOrTitle) {
    final String input = destinationOrTitle.trim();
    if (input.isEmpty) return _defaultImage;
    for (final MapEntry<String, String> entry in _keywordImageMap.entries) {
      if (input.contains(entry.key)) {
        return entry.value;
      }
    }
    final int index = input.hashCode.abs() % _fallbackPool.length;
    return _fallbackPool[index];
  }
}
