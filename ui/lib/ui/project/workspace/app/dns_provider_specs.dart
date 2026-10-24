part of '../../project_workspace.dart';

enum AppDeploymentTlsChallengeMode { http, dns }

class AppDeploymentDnsProviderFieldSpec {
  const AppDeploymentDnsProviderFieldSpec({
    required this.key,
    required this.label,
    this.required = true,
    this.secret = true,
    this.hintText,
  });

  final String key;
  final String label;
  final bool required;
  final bool secret;
  final String? hintText;
}

class AppDeploymentDnsProviderSpec {
  const AppDeploymentDnsProviderSpec({
    required this.id,
    required this.label,
    required this.description,
    required this.fields,
  });

  final String id;
  final String label;
  final String description;
  final List<AppDeploymentDnsProviderFieldSpec> fields;
}

const Map<String, AppDeploymentDnsProviderSpec> _dnsProviderSpecs = {
  'cloudflare': AppDeploymentDnsProviderSpec(
    id: 'cloudflare',
    label: 'Cloudflare',
    description: 'Use a Cloudflare API token for DNS challenge certificates.',
    fields: [
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_token',
        label: 'API token',
        hintText: 'Cloudflare API token',
      ),
    ],
  ),
  'porkbun': AppDeploymentDnsProviderSpec(
    id: 'porkbun',
    label: 'Porkbun',
    description: 'Use Porkbun API credentials for DNS challenge certificates.',
    fields: [
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_key',
        label: 'API key',
        hintText: 'Porkbun API key',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_secret_key',
        label: 'API secret key',
        hintText: 'Porkbun secret key',
      ),
    ],
  ),
  'namecheap': AppDeploymentDnsProviderSpec(
    id: 'namecheap',
    label: 'Namecheap',
    description:
        'Use Namecheap API credentials for DNS challenge certificates.',
    fields: [
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_user',
        label: 'API user',
        hintText: 'Namecheap API username',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_key',
        label: 'API key',
        hintText: 'Namecheap API key',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'client_ip',
        label: 'Client IP (optional)',
        required: false,
        secret: false,
        hintText: 'Optional API allowlisted IP',
      ),
    ],
  ),
  'cloudns': AppDeploymentDnsProviderSpec(
    id: 'cloudns',
    label: 'ClouDNS',
    description: 'Use ClouDNS API credentials for DNS challenge certificates.',
    fields: [
      AppDeploymentDnsProviderFieldSpec(
        key: 'auth_password',
        label: 'Auth password',
        hintText: 'ClouDNS auth password',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'auth_id',
        label: 'Auth ID (optional)',
        required: false,
        secret: false,
        hintText: 'ClouDNS auth ID',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'sub_auth_id',
        label: 'Sub-auth ID (optional)',
        required: false,
        secret: false,
        hintText: 'ClouDNS sub-auth ID',
      ),
    ],
  ),
  'easydns': AppDeploymentDnsProviderSpec(
    id: 'easydns',
    label: 'EasyDNS',
    description: 'Use EasyDNS API credentials for DNS challenge certificates.',
    fields: [
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_token',
        label: 'API token',
        hintText: 'EasyDNS API token',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_key',
        label: 'API key',
        hintText: 'EasyDNS API key',
      ),
      AppDeploymentDnsProviderFieldSpec(
        key: 'api_url',
        label: 'API URL (optional)',
        required: false,
        secret: false,
        hintText: 'Optional EasyDNS API URL override',
      ),
    ],
  ),
};
