import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

class OotdScreen extends StatelessWidget {
  const OotdScreen({super.key});

  static const List<String> _inspirationImages = <String>[
    'https://images.unsplash.com/photo-1464863979621-258859e62245?auto=format&fit=crop&q=80&w=600&h=900',
    'https://images.unsplash.com/photo-1485230895905-ec40ba36b9bc?auto=format&fit=crop&q=80&w=600&h=760',
    'https://images.unsplash.com/photo-1496747611176-843222e1e57c?auto=format&fit=crop&q=80&w=600&h=920',
    'https://images.unsplash.com/photo-1512436991641-6745cdb1723f?auto=format&fit=crop&q=80&w=600&h=780',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black87, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          _buildOotdHeader(),
          _buildMainShowcase(),
          _buildInspirationHeader(),
          _buildInspirationGrid(),
        ],
      ),
    );
  }

  Widget _buildOotdHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: <Widget>[
            Text(
              'OOTD 试衣间',
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.pink.shade50,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.checkroom_outlined,
                    size: 16,
                    color: Colors.pink.shade400,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '我的衣橱',
                    style: TextStyle(
                      color: Colors.pink.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainShowcase() {
    return SliverToBoxAdapter(
      child: Container(
        height: 400,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CachedNetworkImage(
                imageUrl:
                    'https://images.unsplash.com/photo-1515886657613-9f3515b0c78f?auto=format&fit=crop&q=80&w=800',
                fit: BoxFit.cover,
                placeholder: (BuildContext context, String url) {
                  return Container(color: Colors.grey.shade300);
                },
                errorWidget: (BuildContext context, String url, Object error) {
                  return Container(
                    color: Colors.grey.shade300,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.grey.shade600,
                    ),
                  );
                },
              ),
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      color: Colors.white.withOpacity(0.55),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const <Widget>[
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 18,
                            color: Colors.black87,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'AI 一键换装',
                            style: TextStyle(
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: 96,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: <Color>[Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  alignment: Alignment.bottomLeft,
                  child: const Text(
                    '当前场景：巴黎铁塔 🍁 秋季',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInspirationHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 14),
        child: Text(
          '近期热门搭配',
          style: TextStyle(
            color: Colors.grey.shade800,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildInspirationGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverMasonryGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childCount: _inspirationImages.length,
        itemBuilder: (BuildContext context, int index) {
          return Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: CachedNetworkImage(
              imageUrl: _inspirationImages[index],
              fit: BoxFit.cover,
              placeholder: (BuildContext context, String url) {
                return Container(
                  height: 180,
                  color: Colors.grey.shade200,
                );
              },
              errorWidget: (BuildContext context, String url, Object error) {
                return Container(
                  height: 180,
                  color: Colors.grey.shade200,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.grey.shade500,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
