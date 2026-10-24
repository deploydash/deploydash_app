/// Returns the `project_slug` the backend engine addresses [value] by.
///
/// The single owner of "a project name becomes a slug" for the desktop app.
/// The slug names managed containers and directories on a customer's server,
/// so two spellings of this transform address two different containers — the
/// agent API redeploying one while the UI shows the other. That is why this is
/// a top-level function in `utils/` and not a helper on whichever class needed
/// it first: every copy it replaced was a private member that no caller in
/// another layer could reach, which is precisely why it kept being rewritten.
///
/// [fallback] is what a name that normalizes away entirely becomes. It is a
/// parameter rather than a constant because the copies differ in nothing else:
/// `project-scheduler`, `project-db`, `project-workers` and `project-backups`
/// each spell the identical transform again solely to change this one string.
/// D-26 in the duplication-collapse plan owns folding those in; it counts
/// eighteen slug sites in all and prescribes exactly this shape.
String slugifyProjectName(String value, {String fallback = 'project-app'}) {
  final slug = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? fallback : slug;
}
