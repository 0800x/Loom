// Preserve the established Material-style aliases used throughout the app.
// ignore_for_file: constant_identifier_names

import 'package:amicons/amicons.dart';
import 'package:flutter/material.dart';

/// The single icon catalog for Loom UI.
///
/// Every glyph in this catalog comes from the Amicons package. Keep UI code
/// on this surface instead of Flutter's Material [Icons] or CupertinoIcons so
/// iconography stays consistent across the client and shared design package.
abstract final class LoomIcons {
  static const IconData archive_outlined = Amicons.lucide_archive;
  static const IconData history_rounded = Amicons.lucide_history;
  static const IconData help_outline_rounded = Amicons.lucide_circle_help;
  static const IconData wallpaper_rounded = Amicons.lucide_wallpaper;
  static const IconData add = Amicons.lucide_plus;
  static const IconData add_a_photo_outlined = Amicons.lucide_camera;
  static const IconData arrow_upward = Amicons.lucide_arrow_up;
  static const IconData attachment = Amicons.remix_attachment;
  static const IconData broken_image_outlined = Amicons.lucide_image_off;
  static const IconData camera_alt_outlined = Amicons.lucide_camera;
  static const IconData cameraswitch_outlined = Amicons.lucide_switch_camera;
  static const IconData check = Amicons.lucide_check;
  static const IconData close = Amicons.lucide_x;
  static const IconData close_fullscreen_rounded = Amicons.lucide_minimize;
  static const IconData content_paste = Amicons.remix_clipboard;
  static const IconData copy_outlined = Amicons.lucide_copy;
  static const IconData delete_outline = Amicons.lucide_trash2;
  static const IconData delete_outline_rounded = delete_outline;
  static const IconData gif_box_outlined = Amicons.remix_file_gif;
  static const IconData music_note_rounded = Amicons.lucide_music;
  static const IconData queue_music_rounded = Amicons.remix_play_list;
  static const IconData playlist_add_rounded = Amicons.remix_play_list_add;
  static const IconData playlist_play_rounded = Amicons.remix_play_list2;
  static const IconData repeat_rounded = Amicons.lucide_repeat;
  static const IconData repeat_one_rounded = Amicons.lucide_repeat1;
  static const IconData shuffle_rounded = Amicons.lucide_shuffle;
  static const IconData skip_next_rounded = Amicons.lucide_skip_forward;
  static const IconData skip_previous_rounded = Amicons.lucide_skip_back;
  static const IconData replay_10_rounded = Amicons.vuesax_backward_10_seconds;
  static const IconData forward_10_rounded = Amicons.vuesax_forward_10_seconds;
  static const IconData done_all = Amicons.lucide_check_check;
  static const IconData download_rounded = Amicons.lucide_download;
  static const IconData edit_outlined = Amicons.lucide_pencil;
  static const IconData flash_off = Amicons.lucide_zap_off;
  static const IconData flash_on = Amicons.lucide_zap;
  static const IconData folder_open = Amicons.lucide_folder_open;
  static const IconData forward_10 = Amicons.vuesax_forward_10_seconds;
  static const IconData fullscreen_rounded = Amicons.lucide_maximize;
  static const IconData graphic_eq_rounded = Amicons.lucide_audio_waveform;
  static const IconData keyboard_arrow_down_rounded =
      Amicons.lucide_chevron_down;
  static const IconData link = Amicons.remix_link;
  static const IconData map_outlined = Amicons.lucide_map;
  static const IconData mic = Amicons.lucide_mic;
  static const IconData more_vert_rounded = Amicons.remix_more2;
  static const IconData movie_outlined = Amicons.lucide_film;
  static const IconData music_note_outlined = Amicons.lucide_music;
  static const IconData my_location_rounded = Amicons.lucide_locate_fixed;
  static const IconData open_in_new = Amicons.lucide_external_lucidenk;
  static const IconData pause = Amicons.lucide_pause;
  static const IconData pause_rounded = Amicons.lucide_pause;
  static const IconData person = Amicons.lucide_user_round;
  static const IconData person_outline = Amicons.lucide_user_round;
  static const IconData play_arrow = Amicons.lucide_play;
  static const IconData play_arrow_rounded = Amicons.lucide_play;
  static const IconData play_circle_filled_rounded = Amicons.lucide_circle_play;
  static const IconData play_circle_outline = Amicons.lucide_circle_play;
  static const IconData preview_outlined = Amicons.lucide_eye;
  static const IconData refresh = Amicons.lucide_refresh_cw;
  static const IconData remove = Amicons.lucide_minus;
  static const IconData replay_10 = Amicons.vuesax_backward_10_seconds;
  static const IconData send_rounded = Amicons.lucide_send;
  static const IconData share_location_outlined = Amicons.lucide_map_pin;
  static const IconData shield_outlined = Amicons.lucide_shield;
  static const IconData stop = Amicons.lucide_square;
  static const IconData stop_circle_outlined = Amicons.lucide_circle_stop;
  static const IconData text_fields = Amicons.lucide_type;
  static const IconData wifi_tethering = Amicons.lucide_radio;

  static const IconData ad_units_outlined = Amicons.remix_advertisement;
  static const IconData add_call = Amicons.lucide_phone_call;
  static const IconData add_rounded = Amicons.lucide_plus;
  static const IconData add_photo_alternate_outlined =
      Amicons.lucide_image_plus;
  static const IconData admin_panel_settings_outlined =
      Amicons.remix_shield_user;
  static const IconData analytics_outlined = Amicons.lucide_chart_bar;
  static const IconData arrow_back_rounded = Amicons.lucide_arrow_left;
  static const IconData arrow_forward_rounded = Amicons.lucide_arrow_right;
  static const IconData arrow_upward_rounded = Amicons.lucide_arrow_up;
  static const IconData attach_file_rounded = Amicons.remix_attachment;
  static const IconData auto_awesome_rounded = Amicons.lucide_sparkles;
  static const IconData battery_saver_outlined = Amicons.remix_battery;
  static const IconData bluetooth_disabled = Amicons.remix_bluetooth;
  static const IconData bookmark_border_rounded = Amicons.lucide_bookmark;
  static const IconData call_end_rounded = Amicons.lucide_phone_off;
  static const IconData call_made_rounded = Amicons.lucide_arrow_up_right;
  static const IconData call_missed_rounded = Amicons.lucide_phone_off;
  static const IconData call_outlined = Amicons.lucide_phone;
  static const IconData call_rounded = Amicons.lucide_phone;
  static const IconData call_received_rounded = Amicons.lucide_arrow_down_left;
  static const IconData cameraswitch_rounded = Amicons.lucide_switch_camera;
  static const IconData chat_bubble_outline_rounded =
      Amicons.lucide_message_circle;
  static const IconData chat_bubble_rounded = Amicons.lucide_message_circle;
  static const IconData check_circle_rounded = Amicons.lucide_check;
  static const IconData check_rounded = Amicons.lucide_check;
  static const IconData close_rounded = Amicons.lucide_x;
  static const IconData chevron_right_rounded = Amicons.lucide_chevron_right;
  static const IconData circle = Amicons.lucide_circle;
  static const IconData circle_outlined = Amicons.lucide_circle;
  static const IconData cleaning_services_outlined = Amicons.remix_brush;
  static const IconData compare_arrows_rounded =
      Amicons.lucide_arrow_left_right;
  static const IconData contrast_rounded = Amicons.lucide_contrast;
  static const IconData copy_rounded = Amicons.lucide_copy;
  static const IconData dark_mode_outlined = Amicons.lucide_moon;
  static const IconData description_outlined = Amicons.lucide_file_text;
  static const IconData devices_outlined = Amicons.lucide_monitor_smartphone;
  static const IconData dns_outlined = Amicons.lucide_server;
  static const IconData done_all_rounded = Amicons.lucide_check_check;
  static const IconData edit_rounded = Amicons.lucide_pencil;
  static const IconData error_outline_rounded = Amicons.lucide_circle_alert;
  static const IconData fingerprint_rounded = Amicons.lucide_fingerprint;
  static const IconData folder_outlined = Amicons.remix_folder;
  static const IconData forum_outlined = Amicons.lucide_messages_square;
  static const IconData group_add_outlined = Amicons.lucide_user_plus;
  static const IconData groups_outlined = Amicons.lucide_users;
  static const IconData hearing_rounded = Amicons.lucide_ear;
  static const IconData http_rounded = Amicons.lucide_globe;
  static const IconData https_rounded = Amicons.lucide_lock;
  static const IconData hub_outlined = Amicons.lucide_network;
  static const IconData info_outline_rounded = Amicons.lucide_info;
  static const IconData insert_drive_file_outlined = Amicons.lucide_file;
  static const IconData ios_share_rounded = Amicons.lucide_share2;
  static const IconData key_rounded = Amicons.lucide_key;
  static const IconData lan_outlined = Amicons.lucide_network;
  static const IconData language_rounded = Amicons.lucide_languages;
  static const IconData light_mode_outlined = Amicons.lucide_sun;
  static const IconData link_outlined = Amicons.remix_link;
  static const IconData location_on_outlined = Amicons.lucide_map_pin;
  static const IconData lock_outline_rounded = Amicons.lucide_lock;
  static const IconData logout_rounded = Amicons.lucide_log_out;
  static const IconData mic_none_rounded = Amicons.lucide_mic;
  static const IconData mic_off_rounded = Amicons.lucide_mic_off;
  static const IconData mic_rounded = Amicons.lucide_mic;
  static const IconData more_horiz_rounded = Amicons.remix_more;
  static const IconData near_me_outlined = Amicons.lucide_navigation;
  static const IconData notifications_none_rounded = Amicons.lucide_bell;
  static const IconData notifications_off_outlined = Amicons.lucide_bell_off;
  static const IconData offline_bolt_outlined = Amicons.lucide_wifi_off;
  static const IconData palette_outlined = Amicons.lucide_palette;
  static const IconData person_add_alt_1_rounded = Amicons.lucide_user_plus;
  static const IconData person_add_alt_rounded = Amicons.lucide_user_plus;
  static const IconData person_outline_rounded = Amicons.lucide_user_round;
  static const IconData person_remove_outlined = Amicons.lucide_user_minus;
  static const IconData person_search_outlined = Amicons.lucide_user_search;
  static const IconData people_outline_rounded = Amicons.lucide_users;
  static const IconData photo_camera_outlined = Amicons.lucide_camera;
  static const IconData photo_library_outlined = Amicons.lucide_images;
  static const IconData poll_outlined = Amicons.lucide_chart_bar;
  static const IconData push_pin_outlined = Amicons.lucide_pin;
  static const IconData qr_code_2_rounded = Amicons.lucide_qr_code;
  static const IconData qr_code_rounded = Amicons.lucide_qr_code;
  static const IconData qr_code_scanner_rounded = Amicons.lucide_scan_qr_code;
  static const IconData refresh_rounded = Amicons.lucide_refresh_cw;
  static const IconData reply_rounded = Amicons.lucide_reply;
  static const IconData route_outlined = Amicons.lucide_route;
  static const IconData schedule_outlined = Amicons.lucide_clock;
  static const IconData schedule_rounded = Amicons.lucide_clock;
  static const IconData science_outlined = Amicons.remix_flask;
  static const IconData search_rounded = Amicons.lucide_search;
  static const IconData settings_outlined = Amicons.lucide_settings;
  static const IconData storage_outlined = Amicons.lucide_database;
  static const IconData storage_rounded = Amicons.lucide_database;
  static const IconData sync_rounded = Amicons.lucide_refresh_cw;
  static const IconData translate_rounded = Amicons.lucide_languages;
  static const IconData tune_rounded = Amicons.remix_filter;
  static const IconData verified_user_outlined = Amicons.lucide_shield_check;
  static const IconData videocam_off_rounded = Amicons.lucide_video_off;
  static const IconData videocam_outlined = Amicons.lucide_video;
  static const IconData videocam_rounded = Amicons.lucide_video;
  static const IconData visibility_off_outlined = Amicons.lucide_eye_off;
  static const IconData visibility_off_rounded = Amicons.lucide_eye_off;
  static const IconData visibility_outlined = Amicons.lucide_eye;
  static const IconData visibility_rounded = Amicons.lucide_eye;
  static const IconData volume_off_outlined = Amicons.lucide_volume_x;
  static const IconData volume_up_rounded = Amicons.lucide_volume2;
  static const IconData wifi_tethering_rounded = Amicons.lucide_radio;
}

class LoomRouteIcon extends StatelessWidget {
  const LoomRouteIcon({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(
        LoomIcons.route_outlined,
        size: size,
        color: color ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface,
      );
}
