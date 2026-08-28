class CityModel {
  const CityModel({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.subtitle,
    required this.tags,
  });

  final String id;
  final String name;
  final String imageUrl;
  final String subtitle;
  final List<String> tags;

  factory CityModel.fromJson(Map<String, dynamic> json) {
    return CityModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      imageUrl: (json['image_url'] ?? json['imageUrl'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      tags: List<String>.from(json['tags'] ?? <dynamic>[]),
    );
  }
}
