import React from 'react';
// eslint-disable-next-line import/no-extraneous-dependencies
import type { ProjectKind } from '@odh-dashboard/internal/k8sTypes';
import { useWatchDeployments } from './deployments';
import { ModelServingPlatform } from './modelServingPlatforms';
import { Deployment } from '../../extension-points';

type ModelDeploymentsContextType = {
  deployments?: Deployment[];
};

export const ProjectDeploymentsContext = React.createContext<ModelDeploymentsContextType>({
  deployments: undefined,
});

type ProjectDeploymentsProviderProps = {
  project: ProjectKind;
  modelServingPlatform: ModelServingPlatform;
  children: React.ReactNode;
};

export const ProjectDeploymentsProvider: React.FC<ProjectDeploymentsProviderProps> = ({
  project,
  modelServingPlatform,
  children,
}) => {
  const [deployedModels] = useWatchDeployments(project, modelServingPlatform);

  const contextValue = React.useMemo<ModelDeploymentsContextType>(
    () => ({
      deployments: deployedModels,
    }),
    [deployedModels],
  );

  return (
    <ProjectDeploymentsContext.Provider value={contextValue}>
      {children}
    </ProjectDeploymentsContext.Provider>
  );
};
