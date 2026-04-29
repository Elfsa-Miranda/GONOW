import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  static const List<_AssetItem> _assets = <_AssetItem>[
    _AssetItem(
      title: 'AA 账单中心',
      subtitle: '一键清算结伴花销',
      icon: Icons.receipt_long_outlined,
      iconColor: Colors.orange,
      iconBackground: Color(0xFFFFF3E0),
      showAiTag: false,
    ),
    _AssetItem(
      title: '旅行手账',
      subtitle: '零门槛自动生成',
      icon: Icons.menu_book_outlined,
      iconColor: Colors.blue,
      iconBackground: Color(0xFFEAF2FF),
      showAiTag: true,
    ),
    _AssetItem(
      title: '我的衣橱',
      subtitle: 'OOTD试穿收藏',
      icon: Icons.shopping_bag_outlined,
      iconColor: Colors.pink,
      iconBackground: Color(0xFFFFEEF5),
      showAiTag: false,
    ),
    _AssetItem(
      title: '订单中心',
      subtitle: '机酒门票记录',
      icon: Icons.article_outlined,
      iconColor: Colors.indigo,
      iconBackground: Color(0xFFEFF1FF),
      showAiTag: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: <Widget>[
          _buildProfileHeader(),
          _buildFootprintCard(),
          _buildAssetsHeader(),
          _buildAssetsGrid(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 36)),
        ],
      ),
    );
  }

  Widget _buildProfileHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 48, 20, 24),
        child: Row(
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blue.shade50, width: 2),
              ),
              child: ClipOval(
                child: CachedNetworkImage(
                  imageUrl:
                      'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=200',
                  fit: BoxFit.cover,
                  placeholder: (BuildContext context, String url) {
                    return Container(color: Colors.grey.shade200);
                  },
                  errorWidget: (BuildContext context, String url, Object error) {
                    return Container(
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.person_outline_rounded,
                        color: Colors.grey.shade500,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '旅行者_Leo',
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Lv.3 探索家',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.settings_outlined,
              color: Colors.grey.shade400,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFootprintCard() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          height: 120,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[
                Colors.grey.shade900,
                Colors.grey.shade800,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Colors.black12,
                blurRadius: 15,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            children: <Widget>[
              Positioned(
                right: -12,
                top: -26,
                child: Transform.rotate(
                  angle: -0.3,
                  child: Icon(
                    Icons.public,
                    size: 140,
                    color: Colors.white.withOpacity(0.05),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(
                          Icons.explore_outlined,
                          size: 18,
                          color: Colors.lightBlueAccent,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          '世界足迹地图',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    RichText(
                      text: TextSpan(
                        style: TextStyle(
                          color: Colors.grey.shade300,
                          fontSize: 12,
                        ),
                        children: const <InlineSpan>[
                          TextSpan(text: '你已点亮地球上的 '),
                          TextSpan(
                            text: '12',
                            style: TextStyle(
                              color: Colors.lightBlueAccent,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              height: 1.0,
                            ),
                          ),
                          TextSpan(text: ' 个城市'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssetsHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Text(
          '旅行资产',
          style: TextStyle(
            color: Colors.grey.shade800,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildAssetsGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.4,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final _AssetItem item = _assets[index];
            return _AssetCard(item: item);
          },
          childCount: _assets.length,
        ),
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({required this.item});

  final _AssetItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: item.iconBackground,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    item.icon,
                    size: 20,
                    color: item.iconColor,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2E2E2E),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (item.showAiTag)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  '✨ AI生成',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AssetItem {
  const _AssetItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.showAiTag,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final bool showAiTag;
}
