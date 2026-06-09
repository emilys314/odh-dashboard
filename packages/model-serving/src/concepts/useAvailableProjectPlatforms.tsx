import React from 'react';
import { useExtensions } from '@odh-dashboard/plugin-core';
import useFetch, { FetchStateObject } from '@odh-dashboard/internal/utilities/useFetch';
import type { ModelServingPlatform } from './useProjectServingPlatform';
import { isModelServingPlatformExtension } from '../../extension-points';

// If a platform has an integration app name, we need to check if it is available on the cluster
const isPlatformAvailable = async (
  platform: ModelServingPlatform,
  namespace: string | null,
): Promise<boolean> => {
  if (platform.properties.manage.projectRequirements.resourceCheck) {
    return platform.properties.manage.projectRequirements
      .resourceCheck()
      .then((fnc) => fnc(namespace ?? undefined));
  }
  return true;
};

/**
 * @returns The list of platforms that are available for selection on for a project. (Different than the list of all platform plugins)
 */
export const useAvailableProjectPlatforms = (
  namespace: string | null,
): FetchStateObject<ModelServingPlatform[]> => {
  const allPlatforms = useExtensions<ModelServingPlatform>(isModelServingPlatformExtension);

  const callback = React.useCallback(async () => {
    const availablePlatforms = [];
    for (const p of allPlatforms) {
      if (await isPlatformAvailable(p, namespace)) {
        availablePlatforms.push(p);
      }
    }
    return availablePlatforms;
  }, [allPlatforms, namespace]);

  return useFetch<ModelServingPlatform[]>(callback, []);
};
