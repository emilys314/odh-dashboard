import React from 'react';
import ModelsProjectDetailsView from './components/projectDetails/ModelsProjectDetailsView';
import { ProjectDeploymentsProvider } from './concepts/ModelDeploymentsContext';
import { ModelServingContext, ModelServingProvider } from './concepts/ModelServingContext';

const WithDeployments: React.FC = () => {
  const { platform, project } = React.useContext(ModelServingContext);

  if (platform && project) {
    return (
      <ProjectDeploymentsProvider modelServingPlatform={platform} project={project}>
        <ModelsProjectDetailsView />
      </ProjectDeploymentsProvider>
    );
  }
  return <ModelsProjectDetailsView />;
};

const ModelsProjectDetailsTab: React.FC = () => (
  <ModelServingProvider>
    <WithDeployments />
  </ModelServingProvider>
);

export default ModelsProjectDetailsTab;
