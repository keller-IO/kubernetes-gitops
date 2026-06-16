module.exports = {
  platform: 'gitea', // Forgejo is API-compatible with the Gitea platform
  endpoint: 'https://git.jit.services/api/v1', // CHANGE ME
  autodiscover: true,
  // Or pin explicitly:
  // repositories: ['keller.io/keller.io'],
  onboarding: true,
  requireConfig: 'optional',
  gitAuthor: 'Renovate Bot <renovate@jit.services>', // CHANGE ME
};
