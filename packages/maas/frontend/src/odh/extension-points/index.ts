export const MAAS_EXTENSIONS = [
  {
    type: 'maas.models',
    properties: {
      getMaaSModels: import('~/app/api/maas-models.ts').then((module) => module.getMaaSModels),
    },
  },
  {
    type: 'maas.generate-token',
    properties: {
      generateMaaSToken: import('~/app/api/api-keys').then((module) => module.createAPIKey),
    },
  },
];
