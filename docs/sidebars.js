/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Installation',
      items: [
        'installation/quickstart',
        'installation/profiles',
        'installation/gpu-setup',
        'installation/offline-install',
        'installation/requirements',
      ],
    },
    {
      type: 'category',
      label: 'Operations',
      items: [
        'operations/health-monitoring',
        'operations/backup-restore',
        'operations/updates',
        'operations/alerting',
        'operations/incident-response',
      ],
    },
    {
      type: 'category',
      label: 'Security',
      items: [
        'security/overview',
        'security/hardening',
        'security/secret-management',
        'security/network-isolation',
      ],
    },
    {
      type: 'category',
      label: 'Migration',
      items: [
        'migration/version-upgrade',
        'migration/dr-procedures',
      ],
    },
  ],
};

module.exports = sidebars;
