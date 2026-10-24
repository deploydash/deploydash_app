/// Which workspace the shell is showing.
///
/// Its own file because [ShellPage] decides the mode and [WorkspaceBody]
/// renders it, so both need the type and neither should import the other.
/// Split out of `main.dart` with them by T-3.2.5.
enum WorkspaceMode {
  home,
  project,
  createProject,
  addServer,
  serverManagement,
  appSettings,
  unlock,
}
