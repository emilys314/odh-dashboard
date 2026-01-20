import type { CodeRef, Extension } from '@openshift/dynamic-plugin-sdk';
import { ModArchRestGET } from '~/app/types';

export type MaaSModel = {
  id: string;
  name: string;
  description: string;
  created: string;
  updated: string;
  status: string;
};

export const isMaaSModelsExtension = (extension: Extension): extension is MaaSModelsExtension =>
  extension.type === 'maas.models';
export type MaaSModelsExtension = Extension<
  'maas.models',
  {
    // NOTE: I assume you'll want to use ModArchRestGET<MaaSModel[]> instead
    getMaaSModels: CodeRef<() => Promise<MaaSModel[]>>;
  }
>;

export type MaaSToken = {
  token: string;
  expiresAt: number;
};

export const isGenerateMaaSTokenExtension = (
  extension: Extension,
): extension is GenerateMaaSTokenExtension => extension.type === 'maas.generate-token';
export type GenerateMaaSTokenExtension = Extension<
  'maas.generate-token',
  {
    // NOTE: I assume you'll want to use ModArchRestGET<MaaSToken> instead
    generateMaaSToken: CodeRef<ModArchRestGET<MaaSToken>>;
  }
>;
