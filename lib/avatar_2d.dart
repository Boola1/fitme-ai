import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'common.dart';
import 'i18n.dart';
import 'platform/local_files.dart';

class AvatarPhotoStore {
  AvatarPhotoStore._();


  static String? _cachedFor;
  static String? lastCutoutError;

  /// Bumped every time the avatar files are rewritten. The file names never
  /// change, so widgets use this in their keys to show the new picture.
  static int revision = 0;

  /// Every account on this device has its own avatar files (a new user must not see someone else's photo).
  static String get _account {
    final id = Session.user.value?.id ?? 'guest';
    return id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static void _checkAccount() {
    if (_cachedFor != _account) {
      _cachedFor = _account;
      revision++;
    }
  }

  static String get _originalName => 'fitme_avatar_original_$_account.png';

  static String get _previewName => 'fitme_avatar_cutout_$_account.png';

  /// Before v5 the avatar had one name for the whole phone. Those files belonged to the
  /// creator (the only user then): they move to the creator's account, nobody else sees them.
  static Future<void> _claimSharedFiles() async {
    final shared = [
      ('fitme_avatar_original.png', _originalName),
      ('fitme_avatar_cutout.png', _previewName),
      ('fitme_2d_avatar.jpg', _originalName),
    ];
    final isOwner = Session.user.value?.role == 'owner';
    for (final (old, target) in shared) {
      if (!await LocalFiles.exists(old)) continue;
      if (isOwner && !await LocalFiles.exists(target)) {
        await LocalFiles.rename(old, target);
      } else if (isOwner) {
        await LocalFiles.delete(old);
      }
    }
  }

  static Future<XFile?> loadPhoto() async {
    _checkAccount();
    await _claimSharedFiles();
    return LocalFiles.open(_originalName);
  }

  static Future<XFile?> loadPreview() async {
    _checkAccount();
    await _claimSharedFiles();
    return await LocalFiles.open(_previewName) ?? await LocalFiles.open(_originalName);
  }

  static Future<void> saveFromXFile(XFile source) async {
    final sourceBytes = await source.readAsBytes();
    final normalizedPng = await _AvatarCutoutProcessor.normalizeOriginalPng(
      sourceBytes,
    );

    Uint8List previewPng;
    lastCutoutError = null;
    try {
      previewPng = await _requestAiCutout(sourceBytes);
    } catch (error) {
      // Important: never fall back to the old color-key algorithm.
      // It ate white clothes and created the ugly white islands seen in v8.
      previewPng = normalizedPng;
      lastCutoutError = error.toString();
    }

    await LocalFiles.writeBytes(_originalName, normalizedPng);
    await LocalFiles.writeBytes(_previewName, previewPng);
    revision++;
  }

  static Future<Uint8List> _requestAiCutout(Uint8List bytes) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ServerConfig.baseUrl}/api/v1/avatar/cutout'),
    );
    request.headers.addAll(ServerConfig.headers);
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        bytes,
        filename: 'fitme_avatar.jpg',
      ),
    );

    final streamed = await request.send().timeout(Duration(minutes: 3));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw Exception(
        'AI cutout HTTP ${response.statusCode}: ${response.body}',
      );
    }
    if (response.bodyBytes.isEmpty) {
      throw Exception('AI cutout returned an empty image');
    }
    return response.bodyBytes;
  }

  static Future<void> delete() async {
    await LocalFiles.delete(_originalName);
    await LocalFiles.delete(_previewName);
    revision++;
  }
}

class _AvatarCutoutProcessor {
  static Future<Uint8List> normalizeOriginalPng(Uint8List sourceBytes) async {
    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }
}

class Avatar2DPreview extends StatefulWidget {
  const Avatar2DPreview({super.key, this.height = 250});

  final double height;

  @override
  State<Avatar2DPreview> createState() => _Avatar2DPreviewState();
}

class _Avatar2DPreviewState extends State<Avatar2DPreview> {
  XFile? photo;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await AvatarPhotoStore.loadPreview();
    if (!mounted) return;
    setState(() {
      photo = saved;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: FitColors.cardHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: FitColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: loading
          ? Center(child: CircularProgressIndicator())
          : photo == null
          ? _EmptyAvatarPreview()
          : Stack(
              fit: StackFit.expand,
              children: [
                AvatarImage(
                  key: ValueKey('preview-${AvatarPhotoStore.revision}'),
                  photo: photo!,
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _AvatarBadge(text: 'AI CUTOUT'),
                ),
              ],
            ),
    );
  }
}

/// The avatar photo as it is (no stretching: body measurements are not used any more).
class AvatarImage extends StatelessWidget {
  const AvatarImage({super.key, required this.photo});

  final XFile photo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: PhotoImage(
        photo,
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
        errorBuilder: (_, _, _) => const _EmptyAvatarPreview(),
      ),
    );
  }
}

class Avatar2DScreen extends StatefulWidget {
  const Avatar2DScreen({super.key});

  @override
  State<Avatar2DScreen> createState() => _Avatar2DScreenState();
}

class _Avatar2DScreenState extends State<Avatar2DScreen> {
  final picker = ImagePicker();

  XFile? avatar;
  bool loading = true;
  bool picking = false;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final saved = await AvatarPhotoStore.loadPreview();
    if (!mounted) return;
    setState(() {
      avatar = saved;
      loading = false;
    });
  }

  Future<void> _pick(ImageSource source) async {
    final image = await picker.pickImage(
      source: source,
      imageQuality: 94,
      maxWidth: 2200,
    );
    if (image == null || !mounted) return;
    setState(() {
      picking = true;
      loading = avatar == null;
    });
    try {
      await AvatarPhotoStore.saveFromXFile(image);
      final saved = await AvatarPhotoStore.loadPreview();
      if (!mounted) return;
      setState(() => avatar = saved);
    } catch (e) {
      if (mounted) showMessage(context, t('Не удалось сохранить фото: {e}', {'e': e}));
    } finally {
      if (mounted) {
        setState(() {
          picking = false;
          loading = false;
        });
      }
    }

    if (!mounted) return;
    if (AvatarPhotoStore.lastCutoutError != null) {
      showMessage(
        context,
        t('Фото сохранено, но фон не удалён: нет связи с ноутбуком. Попробуйте ещё раз позже.'),
      );
    }
  }

  Future<void> _deleteAvatar() async {
    final ok = await confirmAction(context, title: t('Удалить аватар?'));
    if (!ok) return;
    await AvatarPhotoStore.delete();
    if (!mounted) return;
    setState(() => avatar = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Мой аватар')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('Готово')),
          ),
        ],
      ),
      body: PageWidth(
        child: ListView(
        padding: EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          Container(
            height: 470,
            decoration: BoxDecoration(
              color: FitColors.cardHigh,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: FitColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: loading
                ? Center(child: CircularProgressIndicator())
                : avatar == null
                ? _CreateAvatarHint()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      AvatarImage(
                        key: ValueKey('avatar-${AvatarPhotoStore.revision}'),
                        photo: avatar!,
                      ),
                      if (picking)
                        ColoredBox(
                          color: Color(0x99000000),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text(t('AI убирает фон...'), style: const TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      Positioned(
                        left: 14,
                        bottom: 14,
                        child: _AvatarBadge(text: 'AI CUTOUT'),
                      ),
                    ],
                  ),
          ),
          SizedBox(height: 14),
          if (avatar == null) ...[
            FilledButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.camera),
              icon: Icon(Icons.camera_alt),
              label: Text(t('Сфотографироваться')),
            ),
            SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.gallery),
              icon: Icon(Icons.photo_library_outlined),
              label: Text(t('Добавить фото из галереи')),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.camera),
                    icon: Icon(Icons.camera_alt_outlined),
                    label: Text(t('Новое фото')),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.gallery),
                    icon: Icon(Icons.photo_library_outlined),
                    label: Text(t('Галерея')),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            TextButton.icon(
              onPressed: _deleteAvatar,
              icon: Icon(Icons.delete_outline),
              label: Text(t('Удалить аватар')),
            ),
          ],
          SizedBox(height: 14),
          Container(
            padding: EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: FitColors.card,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              t('Аватар — ваше фото в полный рост без фона. Его можно выбрать на вкладке «Примерка» '
                  'кнопкой «Аватар», чтобы не искать фото каждый раз. Лучше всего подходит снимок '
                  'при хорошем свете, лицом к камере, на простом фоне.'),
              style: TextStyle(color: FitColors.soft, height: 1.4),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _EmptyAvatarPreview extends StatelessWidget {
  const _EmptyAvatarPreview();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_alt_1, size: 58, color: FitColors.accentSoft),
          SizedBox(height: 10),
          Text(
            t('Создайте аватар из своего фото'),
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 4),
          Text(
            t('AI удалит фон автоматически'),
            style: TextStyle(color: FitColors.muted),
          ),
        ],
      ),
    );
  }
}

class _CreateAvatarHint extends StatelessWidget {
  const _CreateAvatarHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.accessibility_new, size: 78, color: FitColors.accentSoft),
          SizedBox(height: 18),
          Text(
            t('Создайте свой аватар'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 8),
          Text(
            t('Сфотографируйтесь в полный рост или выберите готовое фото. '
            'FitMe уберёт фон и оставит только человека.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: FitColors.muted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: FitColors.accentSoft.withValues(alpha: .4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: const Color(0xFFB9AEFF),
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
