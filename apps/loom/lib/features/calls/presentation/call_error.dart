import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/call_session_controller.dart';

String callFailureMessage(BuildContext context, Object error) {
  final raw = error is LoomCallUnavailableException
      ? error.message
      : error is LoomProtocolException
      ? error.message
      : error.toString();
  final code = raw.toLowerCase();
  if (code.contains('video_calls_disabled')) {
    return tr(
      context,
      'Video calling is disabled by a Node administrator. Try a voice call.',
      'تماس تصویری توسط مدیر سرور غیرفعال شده. تماس صوتی را امتحان کنید.',
    );
  }
  if (code.contains('voice_calls_disabled')) {
    return tr(
      context,
      'Voice calling is disabled by a Node administrator.',
      'تماس صوتی توسط مدیر سرور غیرفعال شده است.',
    );
  }
  if (code.contains('calls_disabled') ||
      code.contains('calls are not enabled')) {
    return tr(
      context,
      'Calling is disabled on your Home Node. Its administrator needs to enable calls.',
      'تماس روی سرور شما غیرفعال است. مدیر سرور باید قابلیت تماس را فعال کند.',
    );
  }
  if (code.contains('turn_') ||
      code.contains('turn server') ||
      code.contains('rtc credentials') ||
      code.contains('rtc configuration') ||
      code.contains('rtc_unavailable') ||
      code.contains('not ready for calls')) {
    return tr(
      context,
      'Your Home Node is not configured for calls. Ask its administrator to check the TURN service.',
      'سرور شما برای تماس آماده نیست. از مدیر سرور بخواهید تنظیمات سرویس TURN را بررسی کند.',
    );
  }
  if (code.contains('session expired') ||
      code.contains('access token') ||
      code.contains('sign in') ||
      code.contains('signed-in') ||
      code.contains('signed in') ||
      code.contains('unauthorized')) {
    return tr(
      context,
      'Reconnect to your Home Node and sign in again, then retry the call.',
      'دوباره به سرور خود وصل شوید و وارد حساب شوید، سپس تماس را تکرار کنید.',
    );
  }
  if (code.contains('call_conversation_not_found')) {
    return tr(
      context,
      'This chat has not synced with your Home Node yet. Connect to the internet, sync the chat, and try again.',
      'این گفتگو هنوز با سرور همگام نشده است. اینترنت را وصل کنید و پس از همگام‌سازی دوباره تماس بگیرید.',
    );
  }
  if (code.contains('identity_mismatch')) {
    return tr(
      context,
      'The other person’s identity could not be verified. Check their identity in the chat before retrying.',
      'هویت طرف مقابل تأیید نشد. پیش از تلاش مجدد، هویت او را در گفتگو بررسی کنید.',
    );
  }
  if (code.contains('permission') ||
      code.contains('notallowed') ||
      code.contains('not allowed') ||
      code.contains('denied')) {
    return tr(
      context,
      'Allow microphone access in device settings. Video calls also need camera access.',
      'در تنظیمات دستگاه، دسترسی میکروفون را فعال کنید. تماس تصویری به دسترسی دوربین هم نیاز دارد.',
    );
  }
  if (error is TimeoutException ||
      code.contains('timeout') ||
      code.contains('timed out')) {
    return tr(
      context,
      'The call connection timed out. Check your internet connection and try again.',
      'زمان برقراری تماس تمام شد. اتصال اینترنت را بررسی کنید و دوباره تلاش کنید.',
    );
  }
  if (code.contains('already active') || code.contains('already_in_call')) {
    return tr(
      context,
      'Another call is already active. Return to that call or end it first.',
      'تماس دیگری فعال است. به همان تماس برگردید یا ابتدا آن را پایان دهید.',
    );
  }
  if (code.contains('no compatible') ||
      code.contains('call support') ||
      code.contains('call-support')) {
    return tr(
      context,
      'The other person has no compatible device available for this call.',
      'طرف مقابل دستگاه سازگاری برای این تماس ندارد.',
    );
  }
  return tr(
    context,
    'The call could not connect. Check your internet connection and try again. If it keeps failing, ask your Node administrator to check calling and federation.',
    'تماس برقرار نشد. اتصال اینترنت را بررسی و دوباره تلاش کنید. اگر مشکل ادامه داشت، از مدیر سرور بخواهید سرویس تماس و ارتباط بین سرورها را بررسی کند.',
  );
}

/// Does not depend on a ScaffoldMessenger being present under the caller.
Future<void> showCallFailure(BuildContext context, Object error) {
  final glassQuality = LoomGlassScope.qualityOf(context);
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => LoomGlassScope(
      quality: glassQuality,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: LoomGlassSurface(
          strength: LoomGlassStrength.strong,
          radius: LoomRadii.sheet,
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      dialogContext,
                      'Call could not connect',
                      'تماس برقرار نشد',
                    ),
                    style: Theme.of(dialogContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(callFailureMessage(dialogContext, error)),
                  const SizedBox(height: 20),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(tr(dialogContext, 'Close', 'بستن')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
