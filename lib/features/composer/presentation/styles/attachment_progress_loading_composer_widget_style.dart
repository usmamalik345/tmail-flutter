import 'package:core/presentation/extensions/color_extension.dart';
import 'package:flutter/material.dart';

class AttachmentProgressLoadingComposerWidgetStyle {
  static const double height = 2;
  static const double radius = 1;

  static const Color backgroundColor = AppColor.colorProgressLoadingBackground;
  static const Color progressColor = AppColor.primaryColor;

  /// Marks the staging leg of a drive transfer, which fills the first half of
  /// the same bar [progressColor] then finishes.
  static const Color downloadProgressColor = AppColor.toastSuccessBackgroundColor;
}