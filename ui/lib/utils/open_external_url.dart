import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the external browser when it is an http(s) URL.
///
/// The single owner of "open an external link or ignore it" for the desktop
/// app. Two hand-rolled tryParse+launch blocks preceded it (D-43) — one with
/// an https|http scheme guard, one with a null-check only — which is why it
/// is a top-level function in `utils/` rather than a method on whichever
/// widget happened to need it first: a helper that can only be reached
/// through one widget is a helper the next widget will rewrite.
///
/// Only `http` and `https` URLs launch. Anything else — including
/// `javascript:` URLs and strings [Uri.tryParse] rejects — is silently
/// ignored, because a non-web URL must never reach the OS opener from a UI
/// button that promises to open a web page.
Future<void> openExternalUrl(String url) async {
  final parsed = Uri.tryParse(url);
  if (parsed == null ||
      !(parsed.scheme == 'https' || parsed.scheme == 'http')) {
    return;
  }
  await launchUrl(parsed, mode: LaunchMode.externalApplication);
}
