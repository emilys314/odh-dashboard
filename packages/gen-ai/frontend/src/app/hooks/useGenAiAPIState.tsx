import React from 'react';
import { APIState, useAPIState } from 'mod-arch-core';
import { useExtensions } from '@odh-dashboard/plugin-core';
import { GenAiAPIs } from '~/app/types';
import {
  getBFFConfig,
  getLSDStatus,
  installLSD,
  deleteLSD,
  getAAModels,
  exportCode,
  listVectorStores,
  createVectorStore,
  getLSDModels,
  listVectorStoreFiles,
  deleteVectorStoreFile,
  uploadSource,
  getFileUploadStatus,
  getMCPServerTools,
  getMCPServers,
  getMCPServerStatus,
  createResponse,
} from '~/app/services/llamaStackService';
import { isGenerateMaaSTokenExtension, isMaaSModelsExtension } from '~/odh/extension-points/maas';

export type GenAiAPIState = APIState<GenAiAPIs>;

const useGenAiAPIState = (
  hostPath: string | null,
  queryParameters?: Record<string, unknown>,
): [apiState: GenAiAPIState, refreshAPIState: () => void] => {
  const getMaaSModelsExtension = useExtensions(isMaaSModelsExtension);
  const getMaaSModelsFunction = getMaaSModelsExtension[0].properties.getMaaSModels;

  const generateMaaSTokenExtension = useExtensions(isGenerateMaaSTokenExtension);
  const generateMaaSTokenFunction = generateMaaSTokenExtension[0].properties.generateMaaSToken;

  const createAPI = React.useCallback(
    (path: string) => ({
      listVectorStores: listVectorStores(path, queryParameters),
      listVectorStoreFiles: listVectorStoreFiles(path, queryParameters),
      deleteVectorStoreFile: deleteVectorStoreFile(path, queryParameters),
      createVectorStore: createVectorStore(path, queryParameters),
      uploadSource: uploadSource(path, queryParameters),
      getFileUploadStatus: getFileUploadStatus(path, queryParameters),
      getLSDModels: getLSDModels(path, queryParameters),
      exportCode: exportCode(path, queryParameters),
      createResponse: createResponse(path, queryParameters),
      getLSDStatus: getLSDStatus(path, queryParameters),
      installLSD: installLSD(path, queryParameters),
      deleteLSD: deleteLSD(path, queryParameters),
      getAAModels: getAAModels(path, queryParameters),
      // getMaaSModels: getMaaSModels(path, queryParameters),
      getMaaSModels: () => getMaaSModelsFunction().then((response) => response), // MaaSModel[]
      generateMaaSToken: () => generateMaaSTokenFunction().then((response) => response), // MaaSToken
      getMCPServerTools: getMCPServerTools(path, queryParameters),
      getMCPServers: getMCPServers(path, queryParameters),
      getMCPServerStatus: getMCPServerStatus(path, queryParameters),
      getBFFConfig: getBFFConfig(path, queryParameters),
    }),
    [queryParameters, getMaaSModelsFunction, generateMaaSTokenFunction],
  );

  return useAPIState(hostPath, createAPI);
};

export default useGenAiAPIState;
