part of '../../project_workspace.dart';

Future<Map<String, dynamic>?> buildAppDeploymentConnectionPayload(
  ServerConnectionPayloadResolver resolveConnection,
  Server server,
) {
  return resolveConnection(server);
}
