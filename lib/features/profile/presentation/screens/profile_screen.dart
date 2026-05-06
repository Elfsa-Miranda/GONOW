import 'package:flutter/material.dart';
import 'package:gonow/features/ledger/presentation/screens/ledger_screen.dart';
import 'package:gonow/features/ootd/presentation/screens/ootd_screen.dart';
import 'package:gonow/features/profile/data/profile_provider.dart';
import 'package:gonow/features/profile/presentation/screens/profile_settings_screen.dart';
import 'package:gonow/features/profile/presentation/widgets/footprint_map_widget.dart';
import 'package:provider/provider.dart';

/// 「我的」：黑金足迹矢量地图 + 账本 / 衣橱入口。
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.onOpenOOTD});

  /// 可选：外部自定义打开衣橱；为 null 时默认 push [OotdScreen]。
  final VoidCallback? onOpenOOTD;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ProfileProvider>().fetchProfile();
    });
  }

  List<String> _visitedChina = <String>[
    '北京市',
    '上海市',
    '广东省',
    '四川省',
    '浙江省',
    '新疆维吾尔自治区',
  ];
  List<String> _visitedWorld = <String>[];

  @override
  Widget build(BuildContext context) {
    final double topPad = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: Colors.white,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                top: topPad + 24,
                left: 20,
                right: 20,
                bottom: 24,
              ),
              child: Row(
                children: <Widget>[
                  Consumer<ProfileProvider>(
                    builder: (BuildContext context, ProfileProvider profile, _) {
                      final String url = profile.avatarUrl ?? '';
                      final bool hasAvatar = url.isNotEmpty;
                      return Container(
                        width: 64,
                        height: 64,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.indigo.shade100, width: 2),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: hasAvatar
                              ? _AvatarImage(
                                  key: ValueKey<String>(profile.avatarCacheKey),
                                  url: url,
                                  size: 32,
                                )
                              : Container(
                                  color: Colors.grey.shade200,
                                  child: Icon(Icons.person, size: 32, color: Colors.grey.shade400),
                                ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Consumer<ProfileProvider>(
                      builder: (BuildContext context, ProfileProvider profile, _) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              profile.nickname,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const _LevelBadge(),
                          ],
                        );
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, color: Colors.black45),
                    onPressed: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const ProfileSettingsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: FootprintMapWidget(
                visitedChina: _visitedChina,
                visitedWorld: _visitedWorld,
                onDataChanged: (List<String> newChina, List<String> newWorld) {
                  setState(() {
                    _visitedChina = newChina;
                    _visitedWorld = newWorld;
                  });
                },
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 32, 20, 16),
              child: Text(
                '旅行资产',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                // 真机系统字号放大时略增大单元格高度，避免宫格底部溢出。
                childAspectRatio: 1.1,
              ),
              delegate: SliverChildListDelegate(
                <Widget>[
                  _buildAssetCard(
                    context,
                    title: '旅行账本',
                    subtitle: 'AA清算与票务',
                    icon: Icons.account_balance_wallet_outlined,
                    color: Colors.orange,
                    onTap: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const LedgerScreen(),
                        ),
                      );
                    },
                  ),
                  _buildAssetCard(
                    context,
                    title: '我的衣橱',
                    subtitle: 'OOTD实景试穿',
                    icon: Icons.shopping_bag_outlined,
                    color: Colors.pink,
                    onTap: () {
                      if (widget.onOpenOOTD != null) {
                        widget.onOpenOOTD!();
                      } else {
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const OotdScreen(),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ),
    );
  }

  Widget _buildAssetCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required MaterialColor color,
    bool hasSparkle = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade100),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color.shade500, size: 20),
                ),
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            if (hasSparkle)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade500,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.auto_awesome, color: Colors.white, size: 8),
                      SizedBox(width: 2),
                      Text(
                        'AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  const _LevelBadge();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Lv.3 探索家',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ✅ 与 profile_settings_screen.dart 共享同一套头像渲染逻辑
class _AvatarImage extends StatefulWidget {
  const _AvatarImage({super.key, required this.url, this.size = 32});
  final String url;
  final double size;

  @override
  State<_AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<_AvatarImage> {
  @override
  Widget build(BuildContext context) {
    return Image.network(
      widget.url,
      fit: BoxFit.cover,
      loadingBuilder: (BuildContext ctx, Widget child, ImageChunkEvent? progress) {
        if (progress == null) return child;
        return ColoredBox(
          color: Colors.grey.shade100,
          child: Center(
            child: SizedBox(
              width: widget.size * 0.6,
              height: widget.size * 0.6,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
      errorBuilder: (BuildContext ctx, Object error, StackTrace? stack) {
        return Container(
          color: Colors.grey.shade200,
          child: Icon(Icons.person, size: widget.size, color: Colors.grey.shade400),
        );
      },
    );
  }
}