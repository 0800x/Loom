class LoomWallpaper {
  const LoomWallpaper({
    this.style = 'pattern',
    this.image,
    this.dim = .15,
    this.blur = false,
    this.blurAmount = 6,
    this.parallax = false,
  });
  final String style;
  final String? image;
  final double dim;
  final bool blur;
  final double blurAmount;
  final bool parallax;
  LoomWallpaper copyWith({double? dim, double? blurAmount, bool? parallax}) =>
      LoomWallpaper(
        style: style,
        image: image,
        dim: dim ?? this.dim,
        blur: blurAmount == null ? blur : blurAmount > 0,
        blurAmount: blurAmount ?? this.blurAmount,
        parallax: parallax ?? this.parallax,
      );
  static const styles = [
    'pattern',
    'plain',
    'ocean',
    'sage',
    'dusk',
    'sand',
    'aurora',
    'rose',
    'midnight',
    'lavender',
    'ice',
    'ember',
    'forest',
    'photo',
  ];
  Map<String, Object?> toJson() => {
    'style': style,
    'image': image,
    'dim': dim,
    'blur': blur,
    'blurAmount': blurAmount,
    'parallax': parallax,
  };
  factory LoomWallpaper.fromJson(Map<String, dynamic> json) {
    final style = json['style'];
    final image = json['image'];
    final dim = json['dim'];
    final amount = json['blurAmount'] ?? 6;
    final motion = json['parallax'] ?? false;
    if (amount is! num ||
        !amount.isFinite ||
        amount < 0 ||
        amount > 24 ||
        motion is! bool) {
      throw const FormatException('Invalid wallpaper effects');
    }
    if (!styles.contains(style) ||
        dim is! num ||
        !dim.isFinite ||
        dim < 0 ||
        dim > .8 ||
        json['blur'] is! bool ||
        (style == 'photo' &&
            (image is! String ||
                !RegExp(r'^[a-f0-9]{32}\.jpg$').hasMatch(image)))) {
      throw const FormatException('Invalid wallpaper');
    }
    return LoomWallpaper(
      style: style as String,
      image: style == 'photo' ? image as String : null,
      dim: dim.toDouble(),
      blur: json['blur'] as bool,
      blurAmount: amount.toDouble(),
      parallax: motion,
    );
  }
}
